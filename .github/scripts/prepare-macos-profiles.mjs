import { createHash, sign } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

const requiredEnvironment = [
  'ASC_API_ISSUER_ID',
  'ASC_API_KEY_ID',
  'API_KEY_PATH',
  'SIGNING_IDENTITY_HASH',
  'PROFILE_OUTPUT_DIRECTORY',
  'PROFILE_RESULT_PATH'
]

for (const name of requiredEnvironment) {
  if (!process.env[name]) {
    throw new Error(`Required environment variable ${name} is missing.`)
  }
}

const bundleIdentifiers = [
  'com.gnet.wireroute',
  'com.gnet.wireroute.network-extension'
]

const base64URL = value => Buffer.from(value)
  .toString('base64')
  .replace(/=/g, '')
  .replace(/\+/g, '-')
  .replace(/\//g, '_')

const now = Math.floor(Date.now() / 1000)
const header = base64URL(JSON.stringify({
  alg: 'ES256',
  kid: process.env.ASC_API_KEY_ID,
  typ: 'JWT'
}))
const payload = base64URL(JSON.stringify({
  iss: process.env.ASC_API_ISSUER_ID,
  iat: now - 30,
  exp: now + 600,
  aud: 'appstoreconnect-v1'
}))
const unsignedToken = `${header}.${payload}`
const privateKey = await readFile(process.env.API_KEY_PATH)
const signature = sign('sha256', Buffer.from(unsignedToken), {
  key: privateKey,
  dsaEncoding: 'ieee-p1363'
})
const token = `${unsignedToken}.${base64URL(signature)}`

const apiRequest = async (pathname, options = {}) => {
  const response = await fetch(`https://api.appstoreconnect.apple.com${pathname}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  })
  const responseText = await response.text()
  const responseBody = responseText ? JSON.parse(responseText) : null
  if (!response.ok) {
    const detail = responseBody?.errors
      ?.map(error => error.detail || error.title)
      .filter(Boolean)
      .join('; ') || response.statusText
    throw new Error(`App Store Connect API ${response.status}: ${detail}`)
  }
  return responseBody
}

const certificateQuery = new URLSearchParams({
  'filter[certificateType]': 'DEVELOPER_ID_APPLICATION,DEVELOPER_ID_APPLICATION_G2',
  'fields[certificates]': 'name,certificateType,certificateContent,activated',
  limit: '200'
})
const certificateResponse = await apiRequest(`/v1/certificates?${certificateQuery}`)
const requestedCertificateHash = process.env.SIGNING_IDENTITY_HASH.toUpperCase()
const certificate = certificateResponse.data.find(candidate => {
  const content = candidate.attributes?.certificateContent
  if (!content || candidate.attributes?.activated === false) {
    return false
  }
  const hash = createHash('sha1')
    .update(Buffer.from(content, 'base64'))
    .digest('hex')
    .toUpperCase()
  return hash === requestedCertificateHash
})

if (!certificate) {
  throw new Error('The imported Developer ID Application identity was not found in the developer account.')
}

await mkdir(process.env.PROFILE_OUTPUT_DIRECTORY, { recursive: true })

const findBundleID = async identifier => {
  const query = new URLSearchParams({
    'filter[identifier]': identifier,
    limit: '200'
  })
  const response = await apiRequest(`/v1/bundleIds?${query}`)
  const bundleID = response.data.find(candidate => candidate.attributes?.identifier === identifier)
  if (!bundleID) {
    throw new Error(`Bundle ID ${identifier} is not registered in the developer account.`)
  }
  return bundleID
}

const readBundleIDCapabilities = async bundleID => {
  const query = new URLSearchParams({
    'fields[bundleIdCapabilities]': 'capabilityType,settings'
  })
  const response = await apiRequest(
    `/v1/bundleIds/${bundleID.id}/bundleIdCapabilities?${query}`
  )
  return response.data.map(capability => ({
    capabilityType: capability.attributes?.capabilityType,
    settings: capability.attributes?.settings || []
  }))
}

const createProfile = async (name, bundleID) => apiRequest('/v1/profiles', {
  method: 'POST',
  body: JSON.stringify({
    data: {
      type: 'profiles',
      attributes: {
        name,
        profileType: 'MAC_APP_DIRECT'
      },
      relationships: {
        bundleId: {
          data: { type: 'bundleIds', id: bundleID.id }
        },
        certificates: {
          data: [{ type: 'certificates', id: certificate.id }]
        }
      }
    }
  })
})

const prepareProfile = async identifier => {
  const bundleID = await findBundleID(identifier)
  const capabilities = await readBundleIDCapabilities(bundleID)
  const stableName = `WireRoute GitHub ${identifier} ${certificate.id.slice(0, 8)}`
  const query = new URLSearchParams({
    'filter[name]': stableName,
    'filter[profileType]': 'MAC_APP_DIRECT',
    'filter[profileState]': 'ACTIVE',
    'fields[profiles]': 'name,profileType,profileState,profileContent,uuid',
    limit: '200'
  })
  const existingResponse = await apiRequest(`/v1/profiles?${query}`)
  let profile = existingResponse.data[0]

  if (!profile) {
    const createdResponse = await createProfile(stableName, bundleID)
    profile = createdResponse.data
  }

  const profileContent = profile.attributes?.profileContent
  const profileUUID = profile.attributes?.uuid
  if (!profileContent || !profileUUID) {
    throw new Error(`Profile data for ${identifier} is incomplete.`)
  }

  const profilePath = path.join(
    process.env.PROFILE_OUTPUT_DIRECTORY,
    `${profileUUID}.provisionprofile`
  )
  await writeFile(profilePath, Buffer.from(profileContent, 'base64'), { mode: 0o600 })
  console.log(`Prepared ${profile.attributes.name} (${profileUUID}).`)

  return {
    id: profile.id,
    name: profile.attributes.name,
    uuid: profileUUID,
    path: profilePath,
    capabilities
  }
}

const results = {}
for (const identifier of bundleIdentifiers) {
  results[identifier] = await prepareProfile(identifier)
}

await writeFile(
  process.env.PROFILE_RESULT_PATH,
  JSON.stringify({ profiles: results }, null, 2),
  { mode: 0o600 }
)
