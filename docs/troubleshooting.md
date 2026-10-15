# Troubleshooting

Common errors, what they mean, and how to fix them. Find the message you're seeing, or the step that failed.

## Contents

- [Setup errors (exit 1)](#setup-errors-exit-1)
- [Veracode CLI install](#veracode-cli-install)
- [Java API wrapper download](#java-api-wrapper-download)
- [SVN errors](#svn-errors)
- [Packaging fails](#packaging-fails)
- [Pipeline scan problems](#pipeline-scan-problems)
- [Policy scan problems](#policy-scan-problems)
- [SCA problems](#sca-problems)
- [Proxies and firewalls](#proxies-and-firewalls)
- [Still stuck](#still-stuck)

## Setup errors (exit 1)

These come from the script's own checks, before anything runs. The `[ERROR]` line says what's missing.

| Message | Fix |
|---|---|
| Help text is printed and nothing runs | You didn't pass `-u`, or used an unknown flag. Check the command |
| `Mode must be pipeline, policy or both` | Typo in `-m` |
| `VERACODE_API_KEY_ID and VERACODE_API_KEY_SECRET must be set` | Export both variables, or bind them in Jenkins |
| `Policy mode needs an app name (-a)` | Add `-a "Profile Name"` for `policy` or `both` |
| `VERACODE_WRAPPER_JAR is set but no file exists at ...` | The path is wrong. Fix it, or unset the variable and let the script download the wrapper |
| `java is required for policy mode` | Install Java, or check it's on the PATH for the CI user |
| `SRCCLR_API_TOKEN must be set for SCA (-s)` | Export the token, or drop `-s` |
| `svn client not found` | Install the `subversion` package |
| `Permission denied` running the script | `chmod +x veracode-svn-scan.sh`, or run it as `bash veracode-svn-scan.sh` |
| `$'\r': command not found` | The script has Windows line endings. `sed -i 's/\r$//' veracode-svn-scan.sh`. The repo's `.gitattributes` prevents this for fresh clones |

## Veracode CLI install

If `veracode` isn't on the PATH, the script downloads and installs it into the current folder, then adds that folder to the PATH for the rest of the run. It doesn't download the Java API wrapper. That one you install yourself.

| Problem | Fix |
|---|---|
| `curl: (6) Could not resolve host: tools.veracode.com` or a timeout | The agent can't reach the internet. See [proxies](#proxies-and-firewalls), or pre-install the CLI ([use case 16](use-cases.md#16-using-a-pre-installed-or-pinned-veracode-cli)) |
| `Permission denied` during install | The current folder isn't writable. Run from a writable folder, or pre-install the CLI |
| A different CLI version every run | Expected when it auto-installs. Pre-install to pin it |
| Parallel runs fail installing at the same time | Pre-install the CLI once on the agent |

## Java API wrapper download

In policy mode, if `VERACODE_WRAPPER_JAR` isn't set, the script downloads the wrapper from Maven Central into `~/.cache/veracode-svn-scan` (or `VERACODE_TOOLS_DIR`) and reuses it on later runs.

| Problem | Fix |
|---|---|
| `Could not find the latest Java API wrapper version at ...` | The agent can't reach Maven Central, or a proxy blocked it. Set `VERACODE_WRAPPER_REPO` to your Nexus or Artifactory proxy of Maven Central, see [proxies](#proxies-and-firewalls), or set `VERACODE_WRAPPER_VERSION` and pre-place the jar |
| `Could not download https://...jar` | The version doesn't exist (check `VERACODE_WRAPPER_VERSION`), or the network dropped |
| `Checksum mismatch for the Java API wrapper` | The download was corrupted or altered. The bad file is deleted. Run again, and if it keeps happening check whether a proxy is rewriting downloads |
| `Warning: no .sha1 checksum found` | Your repository proxy doesn't serve checksum files. The jar is used without verification. Turn on checksum passthrough in the proxy if you can |
| Downloads every run | The cache folder isn't persistent (common on pod agents). Point `VERACODE_TOOLS_DIR` at a persistent volume, or set `VERACODE_WRAPPER_JAR` to a pre-installed copy |
| No write access to the cache folder | Set `VERACODE_TOOLS_DIR` to a writable folder |

## SVN errors

| Error | Meaning | Fix |
|---|---|---|
| `E170013: Unable to connect to a repository` | Wrong URL, server down, or network blocked | `svn info <url>` from the agent. Check DNS, firewall and proxy |
| `E215004: No more credentials or we tried too many times` | Credentials missing or wrong | Check `SVN_USERNAME` and `SVN_PASSWORD`. See [SVN authentication](svn-authentication.md) |
| `E170001: Authentication failed` / `Authorization failed` | Login works but the account can't read that path | Ask the SVN admin to grant read access |
| `E230001: Server SSL certificate verification failed` | The server's certificate isn't trusted | See [certificates](svn-authentication.md#self-signed-or-internal-certificates) |
| `E160013: path not found` | The URL doesn't exist, or didn't exist at that revision | `svn ls` the parent folder. For old revisions, check when the path was created |
| `E205000: Syntax error in revision argument` | Bad `-r` value | Use a number, `HEAD`, or a quoted date like `'{2026-09-01}'` |
| `--show-item` not recognised | SVN client older than 1.9 | Upgrade the client |
| Export is very slow | Big repo, slow link, or large binaries in SVN | Point `-u` at the app's folder only ([use case 9](use-cases.md#9-one-app-inside-a-larger-svn-repo)) |
| An `svn:externals` path fails | The external points somewhere the account can't read | Check with `svn propget svn:externals -R <url>` |

## Packaging fails

Exit code `2`. The autopackager couldn't build the app or didn't find anything to package.

### First steps

```bash
# What does the autopackager think this project is?
veracode package discover veracode-work/src

# Run packaging again with verbose output
veracode package --source veracode-work/src --output veracode-work/verascan --trust --debug
```

### Common causes

| Symptom | Cause | Fix |
|---|---|---|
| "Unsupported" or no language detected | The language or build tool isn't supported, or the build file isn't at the top of the export | Point `-u` at the folder with the `pom.xml`, `build.gradle`, `.sln` or `package.json`. For unsupported languages see [use case 12](use-cases.md#12-the-language-isnt-supported-by-the-autopackager) |
| `mvn: command not found`, `dotnet: command not found` | Build tool missing on the agent | Install it, or use an agent or image that has it |
| Compiler errors about Java version | Wrong JDK | Check what the project expects (`maven.compiler.release`, `sourceCompatibility`) and set `JAVA_HOME` |
| Dependency download failures | No access to Maven Central or your Nexus / Artifactory | Check `~/.m2/settings.xml`, npm config, proxy settings |
| Build fails on a missing sibling project | The app needs a folder that wasn't exported | See [use case 9](use-cases.md#9-one-app-inside-a-larger-svn-repo) |
| Tests fail during the build | The autopackager runs a real build | Fix the tests, or check whether your build skips them for packaging |
| `No artifacts produced in ...` | The build worked but didn't make a WAR, JAR, EAR or ZIP in the output folder | `ls -R veracode-work/verascan` to see what it did make. The script only picks up those four types |
| Out of memory | Big build on a small agent or pod | Raise memory, or set `MAVEN_OPTS=-Xmx2g` |

## Pipeline scan problems

| Problem | Fix |
|---|---|
| Exit 3 but you expected a clean scan | Exit 3 means findings **or** a failure. Check the log and `results/pipeline-*.json` |
| `unknown flag: --results-file` | The flag name differs in your CLI version. Run `veracode static scan --help` and update the script |
| Artifact too large | Pipeline scans have a size limit. Use a policy scan for big apps, or check the packaging didn't pull in more than it should |
| Authentication errors | Check the API ID and key, and that the account has permission for pipeline scans |
| Scan takes much longer than usual | Usually the Veracode service. Retry later, and check the Veracode status page |

## Policy scan problems

| Problem | Fix |
|---|---|
| App profile not found | The `-a` name must match the Platform exactly, including case and spaces. Or change `-createprofile false` to `true` in the script |
| "A scan is already in progress" | Veracode allows one policy scan per app at a time. Wait, or use a lock in Jenkins ([timeouts and concurrency](jenkins-cloudbees.md#timeouts-and-concurrency)) |
| Times out | Big app. Raise `POLICY_SCAN_TIMEOUT` (minutes) and your CI job timeout |
| `Did not pass` / exit 4 | The scan worked and the app doesn't meet policy. Review the findings in the Platform |
| `Unable to access jarfile` | `VERACODE_WRAPPER_JAR` path is wrong |
| `UnsupportedClassVersionError` | The Java version is too old for the wrapper jar. Use a newer Java |
| `403` or permission errors | The API account lacks permission to upload or scan for that app. Check its roles in the Platform |

## SCA problems

| Problem | Fix |
|---|---|
| `curl` can't reach `download.sourceclear.com` | Network or proxy. See [proxies](#proxies-and-firewalls) |
| Invalid token | Check `SRCCLR_API_TOKEN` and that the agent belongs to the right SCA workspace |
| "No supported build systems found" | SCA looks for `pom.xml`, `build.gradle`, `package.json` and so on in the folder. Check the export has them at the top |
| Can't resolve dependencies | Same as packaging: the build tool and repository access are needed |

## Proxies and firewalls

If the agent goes through a corporate proxy, set the standard variables before running the script:

```bash
export HTTPS_PROXY=http://proxy.example.com:8080
export HTTP_PROXY=http://proxy.example.com:8080
export NO_PROXY=localhost,127.0.0.1,svn.example.com,.example.com
```

`curl`, the Veracode CLI and the SCA agent use these.

**SVN** uses its own proxy settings in `~/.subversion/servers`:

```ini
[global]
http-proxy-host = proxy.example.com
http-proxy-port = 8080
http-proxy-exceptions = *.example.com
```

**The Java wrapper** takes proxy flags. Add them to the policy scan command in the script:

```
-phost proxy.example.com -pport 8080
```

**Maven, Gradle, npm** each have their own proxy settings (`~/.m2/settings.xml`, `gradle.properties`, `.npmrc`).

### Hosts the agent needs to reach

| Host | Used by |
|---|---|
| Your SVN server | Export |
| `tools.veracode.com` | CLI install (skip if pre-installed) |
| `repo1.maven.org`, or your Maven proxy via `VERACODE_WRAPPER_REPO` | Java API wrapper download (skip if `VERACODE_WRAPPER_JAR` is set) |
| `*.veracode.com` | Pipeline and policy scans |
| `download.sourceclear.com` and the SCA API hosts | SCA |
| Maven Central, npm registry, NuGet, or your internal mirror | Packaging builds |

If the proxy does TLS inspection, the agent also needs your company's root CA in its trust stores (system, Java `cacerts`, and SVN's `ssl-authority-files`).

## Still stuck

1. Re-run with tracing and save the output:

   ```bash
   bash -x ./veracode-svn-scan.sh -u ... 2>&1 | tee debug.log
   ```

   **This prints your passwords and API keys.** Scrub them before sharing the log.

2. Re-run just the failing step by hand ([use case 17](use-cases.md#17-debugging-a-scan-that-went-wrong)).
3. For Veracode errors, include the CLI version (`veracode version`), the command and the error when you contact Veracode support.
