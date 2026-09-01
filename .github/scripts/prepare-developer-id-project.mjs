import { readFile, writeFile } from 'node:fs/promises'

const projectPath = process.argv[2]
const infoPlistPath = process.argv[3]
const entryPointPath = process.argv[4]
const appDelegatePath = process.argv[5]
const loginItemHelperPath = process.argv[6]
const loginItemHelperEntitlementsPath = process.argv[7]

if (
  !projectPath ||
  !infoPlistPath ||
  !entryPointPath ||
  !appDelegatePath ||
  !loginItemHelperPath ||
  !loginItemHelperEntitlementsPath
) {
  throw new Error(
    'Usage: prepare-developer-id-project.mjs <project.pbxproj> <Info.plist> <main.swift> <AppDelegate.swift> <LoginItemHelper/main.m> <LoginItemHelper.entitlements>'
  )
}

let project = await readFile(projectPath, 'utf8')

const replaceExactly = (source, search, replacement, expectedCount = 1) => {
  const count = source.split(search).length - 1
  if (count !== expectedCount) {
    throw new Error(`Expected ${expectedCount} occurrence(s) of ${JSON.stringify(search)}, found ${count}.`)
  }
  return source.split(search).join(replacement)
}

const appExtensionName = 'WireRouteNetworkExtension.appex'
const systemExtensionName = 'com.gnet.wireroute.network-extension.systemextension'

project = replaceExactly(
  project,
  `6FB1BD9921D4BFE700A991BF /* ${appExtensionName} in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = 6FB1BD9121D4BFE600A991BF /* ${appExtensionName} */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };`,
  `6FB1BD9921D4BFE700A991BF /* ${systemExtensionName} in Embed System Extensions */ = {isa = PBXBuildFile; fileRef = 6FB1BD9121D4BFE600A991BF /* ${systemExtensionName} */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };`
)

project = replaceExactly(
  project,
  '6FB1BD9121D4BFE600A991BF /* WireRouteNetworkExtension.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = WireRouteNetworkExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; };',
  `6FB1BD9121D4BFE600A991BF /* ${systemExtensionName} */ = {isa = PBXFileReference; explicitFileType = "wrapper.system-extension"; includeInIndex = 0; path = ${systemExtensionName}; sourceTree = BUILT_PRODUCTS_DIR; };`
)

project = replaceExactly(
  project,
  `6FB1BD9D21D4BFE700A991BF /* Embed Foundation Extensions */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t6FB1BD9921D4BFE700A991BF /* ${appExtensionName} in Embed Foundation Extensions */,
\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};`,
  `6FB1BD9D21D4BFE700A991BF /* Embed System Extensions */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "$(SYSTEM_EXTENSIONS_FOLDER_PATH)";
\t\t\tdstSubfolderSpec = 16;
\t\t\tfiles = (
\t\t\t\t6FB1BD9921D4BFE700A991BF /* ${systemExtensionName} in Embed System Extensions */,
\t\t\t);
\t\t\tname = "Embed System Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};`
)

project = replaceExactly(
  project,
  `6FB1BD9121D4BFE600A991BF /* ${appExtensionName} */,`,
  `6FB1BD9121D4BFE600A991BF /* ${systemExtensionName} */,`
)

project = replaceExactly(
  project,
  `productReference = 6FB1BD9121D4BFE600A991BF /* ${appExtensionName} */;\n\t\t\tproductType = "com.apple.product-type.app-extension";`,
  `productReference = 6FB1BD9121D4BFE600A991BF /* ${systemExtensionName} */;\n\t\t\tproductType = "com.apple.product-type.system-extension";`
)

project = replaceExactly(
  project,
  `\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(APP_ID_MACOS).network-extension";\n\t\t\t\tPRODUCT_NAME = WireRouteNetworkExtension;`,
  `\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(APP_ID_MACOS).network-extension";\n\t\t\t\tPRODUCT_NAME = "$(PRODUCT_BUNDLE_IDENTIFIER)";`,
  2
)

project = replaceExactly(
  project,
  '/* Begin PBXBuildFile section */',
  '/* Begin PBXBuildFile section */\n\t\tC0DE30000000000000000001 /* DeveloperIDSystemExtensionMain.swift in Sources */ = {isa = PBXBuildFile; fileRef = C0DE30000000000000000002 /* DeveloperIDSystemExtensionMain.swift */; };'
)

project = replaceExactly(
  project,
  '/* Begin PBXFileReference section */',
  '/* Begin PBXFileReference section */\n\t\tC0DE30000000000000000002 /* DeveloperIDSystemExtensionMain.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeveloperIDSystemExtensionMain.swift; sourceTree = "<group>"; };'
)

project = replaceExactly(
  project,
  '6F5D0C1B218352EF000F85AD /* WireGuardNetworkExtension */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (',
  '6F5D0C1B218352EF000F85AD /* WireGuardNetworkExtension */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\tC0DE30000000000000000002 /* DeveloperIDSystemExtensionMain.swift */,'
)

project = replaceExactly(
  project,
  '6FB1BD8D21D4BFE600A991BF /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (',
  '6FB1BD8D21D4BFE600A991BF /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tC0DE30000000000000000001 /* DeveloperIDSystemExtensionMain.swift in Sources */,'
)

await writeFile(projectPath, project)

const infoPlist = await readFile(infoPlistPath, 'utf8')
const extensionDictionary = `\t<key>NSExtension</key>
\t<dict>
\t\t<key>NSExtensionPointIdentifier</key>
\t\t<string>com.apple.networkextension.packet-tunnel</string>
\t\t<key>NSExtensionPrincipalClass</key>
\t\t<string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
\t</dict>`
const systemExtensionDictionary = `\t<key>NetworkExtension</key>
\t<dict>
\t\t<key>NEProviderClasses</key>
\t\t<dict>
\t\t\t<key>com.apple.networkextension.packet-tunnel</key>
\t\t\t<string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
\t\t</dict>
\t</dict>
\t<key>NSSystemExtensionUsageDescription</key>
\t<string>WireRoute uses this system extension to run WireGuard VPN tunnels.</string>`

let updatedInfoPlist = replaceExactly(
  infoPlist,
  extensionDictionary,
  systemExtensionDictionary
)
updatedInfoPlist = replaceExactly(
  updatedInfoPlist,
  '<string>XPC!</string>',
  '<string>SYSX</string>'
)
await writeFile(infoPlistPath, updatedInfoPlist)

await writeFile(
  entryPointPath,
  `import Dispatch\nimport NetworkExtension\n\n@main\nprivate enum DeveloperIDSystemExtensionMain {\n    static func main() {\n        NEProvider.startSystemExtensionMode()\n        dispatchMain()\n    }\n}\n`
)

let appDelegate = await readFile(appDelegatePath, 'utf8')
appDelegate = replaceExactly(
  appDelegate,
  `        var isLaunchedAtLogin = false
        if let appleEvent = NSAppleEventManager.shared().currentAppleEvent {
            isLaunchedAtLogin = LaunchedAtLoginDetector.isLaunchedAtLogin(openAppleEvent: appleEvent)
        }`,
  `        var isLaunchedAtLogin = ProcessInfo.processInfo.arguments.contains("--wireroute-launched-at-login")
        if !isLaunchedAtLogin, let appleEvent = NSAppleEventManager.shared().currentAppleEvent {
            isLaunchedAtLogin = LaunchedAtLoginDetector.isLaunchedAtLogin(openAppleEvent: appleEvent)
        }`
)
await writeFile(appDelegatePath, appDelegate)

await writeFile(
  loginItemHelperPath,
  `// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

#import <Cocoa/Cocoa.h>

int main(int argc, char *argv[])
{
    NSString *appId = [NSBundle.mainBundle objectForInfoDictionaryKey:@"com.wireguard.macos.app_id"];
    if (!appId)
        return 1;

    NSCondition *condition = [[NSCondition alloc] init];
    NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:appId];
    if (!appURL)
        return 2;
    NSWorkspaceOpenConfiguration *openConfiguration = [NSWorkspaceOpenConfiguration configuration];
    openConfiguration.activates = NO;
    openConfiguration.addsToRecentItems = NO;
    openConfiguration.hides = YES;
    openConfiguration.arguments = @[@"--wireroute-launched-at-login"];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:appURL configuration:openConfiguration completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {
        [condition signal];
    }];
    [condition wait];
    return 0;
}
`
)

let loginItemHelperEntitlements = await readFile(loginItemHelperEntitlementsPath, 'utf8')
loginItemHelperEntitlements = replaceExactly(
  loginItemHelperEntitlements,
  `\t<key>com.apple.security.application-groups</key>
\t<array>
\t\t<string>$(DEVELOPMENT_TEAM).group.$(APP_ID_MACOS)</string>
\t</array>
`,
  ''
)
await writeFile(loginItemHelperEntitlementsPath, loginItemHelperEntitlements)
