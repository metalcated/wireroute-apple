# WireRoute for iOS and macOS

WireRoute is a native client for standard WireGuard tunnels with a simple Split/Full routing control. It is initially focused on private iPhone testing against RouterOS, while retaining a shared macOS foundation.

WireRoute is based on the official [WireGuard Apple](https://git.zx2c4.com/wireguard-apple) project. It does not include AmneziaWG, Xray, or modified tunnel protocols.

The project currently contains the inherited iOS and macOS applications, their packet-tunnel extensions, WireGuardKit, and a new Swift 6 `WireRouteCore` package for profile-derived routing policy. Environment-specific tunnel addresses, endpoints, keys, DNS servers, and routes belong to imported profiles or user settings—not source code.

WireRoute is intended to remain free and open source under the MIT License.

## Support, Privacy, and Legal

- [Secure RouterOS WireGuard setup](ROUTEROS_SETUP.md)
- [Support and contact](SUPPORT.md)
- [Privacy policy](PRIVACY.md)
- [Security reporting](SECURITY.md)
- [Legal and open-source notices](LEGAL.md)
- [MIT License](COPYING)

## Building

- Clone this repo:

```
$ git clone https://github.com/metalcated/wireroute-apple.git
$ cd wireroute-apple
```

- Create a local signing configuration:

```
$ cp Sources/WireGuardApp/Config/Developer.xcconfig.template Sources/WireGuardApp/Config/Developer.xcconfig
$ open -e Sources/WireGuardApp/Config/Developer.xcconfig
```

- Set your Apple Developer Team ID. Use `com.gnet.wireroute` as the base App ID for both platforms. The project derives `com.gnet.wireroute.network-extension` and `com.gnet.wireroute.login-item-helper` for the nested macOS bundles, so the base ID must not include an additional `.macos` suffix. Register the app and Network Extension identifiers with the required capabilities before signing.

- Install the build tools required by the inherited tunnel bridge:

```
$ brew install swiftlint go
```

- Open project in Xcode:

```
$ open WireGuard.xcodeproj
```

Select the `WireGuardiOS` scheme for the first device milestone. Internal target names remain unchanged temporarily to keep the upstream history and project migration reviewable; built products are branded WireRoute.

## Routing behavior

- Split mode uses the profile's specific `AllowedIPs`.
- Full mode computes the default route for every IP family supported by the profile.
- Full mode blocks an unsupported IP family instead of allowing traffic to leak outside the tunnel.
- If an imported profile contains only default routes, Split mode is blocked until specific routes are provided. A route-entry modal is the next UI milestone.
- Switching modes updates the saved effective configuration while preserving the original specific routes in profile metadata for later restoration.
- No RouterOS address, endpoint, key, DNS server, or customer route is hard-coded. The only fixed IPs are RFC documentation addresses used internally as non-routable sinks when Full mode must block an unsupported address family.

Run the Swift 6 package tests with:

```sh
swift test
```

## WireGuardKit integration

1. Open your Xcode project and add the Swift package with the following URL:
   
   ```
   https://git.zx2c4.com/wireguard-apple
   ```
   
2. `WireGuardKit` links against `wireguard-go-bridge` library, but it cannot build it automatically
   due to Swift package manager limitations. So it needs a little help from a developer. 
   Please follow the instructions below to create a build target(s) for `wireguard-go-bridge`.
   
   - In Xcode, click File -> New -> Target. Switch to "Other" tab and choose "External Build 
     System".
   - Type in `WireGuardGoBridge<PLATFORM>` under the "Product name", replacing the `<PLATFORM>` 
     placeholder with the name of the platform. For example, when targeting macOS use `macOS`, or 
     when targeting iOS use `iOS`.
     Make sure the build tool is set to: `/usr/bin/make` (default).
   - In the appeared "Info" tab of a newly created target, type in the "Directory" path under 
     the "External Build Tool Configuration":
     
     ```
     ${BUILD_DIR%Build/*}SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo
     ```
     
   - Switch to "Build Settings" and find `SDKROOT`.
     Type in `macosx` if you target macOS, or type in `iphoneos` if you target iOS.
   
3. Go to Xcode project settings and locate your network extension target and switch to 
   "Build Phases" tab.
   
   - Locate "Dependencies" section and hit "+" to add `WireGuardGoBridge<PLATFORM>` replacing 
     the `<PLATFORM>` placeholder with the name of platform matching the network extension 
     deployment target (i.e macOS or iOS).
     
   - Locate the "Link with binary libraries" section and hit "+" to add `WireGuardKit`.
   
4. In Xcode project settings, locate your main bundle app and switch to "Build Phases" tab. 
   Locate the "Link with binary libraries" section and hit "+" to add `WireGuardKit`.
   
5. iOS only: Locate Bitcode settings under your application target, Build settings -> Enable Bitcode, 
   change the corresponding value to "No".
   
Note that if you ship your app for both iOS and macOS, make sure to repeat the steps 2-4 twice, 
once per platform.

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
