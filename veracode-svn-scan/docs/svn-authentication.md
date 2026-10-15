# SVN authentication

How the script logs in to SVN, how to give it credentials in different setups, and how to keep those credentials safe.

## Contents

- [How it works](#how-it-works)
- [Anonymous access](#anonymous-access)
- [Username and password from the command line](#username-and-password-from-the-command-line)
- [Username and password in Jenkins / CloudBees CI](#username-and-password-in-jenkins--cloudbees-ci)
- [Username and password from a secrets manager](#username-and-password-from-a-secrets-manager)
- [Service accounts](#service-accounts)
- [svn+ssh:// repositories](#svnssh-repositories)
- [Self-signed or internal certificates](#self-signed-or-internal-certificates)
- [The process list caveat](#the-process-list-caveat)
- [Checklist](#checklist)

## How it works

The script talks to SVN twice: once with `svn info` to look up the revision, and once with `svn export` to get the code. Both calls use the same options.

| Situation | What the script passes to `svn` |
|---|---|
| `SVN_USERNAME` is **not** set | `--non-interactive` only |
| `SVN_USERNAME` **is** set | `--non-interactive --username "$SVN_USERNAME" --password "$SVN_PASSWORD" --no-auth-cache` |

What those options do:

| Option | Effect |
|---|---|
| `--non-interactive` | SVN never stops to ask for anything. If it needs a password or a certificate decision it doesn't have, it fails straight away. Without this, a CI job would sit at a hidden prompt until it timed out. |
| `--username` / `--password` | The login to use |
| `--no-auth-cache` | SVN doesn't save the credentials to `~/.subversion/auth`. Nothing is left on the agent after the run. |

Notes:

- `SVN_PASSWORD` is only used when `SVN_USERNAME` is set. Setting just the password does nothing.
- If `SVN_USERNAME` is set but `SVN_PASSWORD` isn't, the script passes an empty password. Most servers reject that.
- If `SVN_USERNAME` isn't set, SVN can still use credentials already cached on the machine from an earlier manual `svn` command. That's convenient on your own workstation, but don't rely on it in CI, because it ties the job to whoever last logged in on that agent.
- The script only reads from SVN. It never commits, locks or changes anything, so the account only needs **read** access to the paths you scan.

## Anonymous access

If your SVN server allows anonymous reads, don't set anything:

```bash
unset SVN_USERNAME SVN_PASSWORD
./veracode-svn-scan.sh -u https://svn.example.com/repos/public-app/trunk
```

## Username and password from the command line

```bash
export SVN_USERNAME='rob'
export SVN_PASSWORD='My$ecret!Pass'
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk
```

### Quoting

Always use **single quotes** around the password. In double quotes, the shell treats `$`, `` ` ``, `\` and sometimes `!` as special, so `"My$ecret!Pass"` would silently turn into something else.

If the password itself contains a single quote, close the quotes, add an escaped quote, and reopen:

```bash
export SVN_PASSWORD='it'\''s-a-secret'      # the password is: it's-a-secret
```

You don't need to worry about quoting inside the script. It passes the value through exactly as it is.

### Keeping it out of your shell history

`export SVN_PASSWORD='...'` is saved in `~/.bash_history`. Two ways to avoid that:

Read it without echoing:

```bash
read -rsp 'SVN password: ' SVN_PASSWORD && export SVN_PASSWORD && echo
```

Or keep it in a file only you can read:

```bash
cat > ~/.svn-scan.env <<'EOF'
export SVN_USERNAME='rob'
export SVN_PASSWORD='My$ecret!Pass'
EOF
chmod 600 ~/.svn-scan.env

. ~/.svn-scan.env
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk
```

### Setting it for one run only

```bash
SVN_USERNAME='rob' SVN_PASSWORD='My$ecret!Pass' ./veracode-svn-scan.sh -u ...
```

The values only exist for that one command and don't stay in your shell. They do still end up in your history, though.

### Domain accounts

If SVN authenticates against Active Directory, you might need the domain in the username. Try the format your SVN admin uses:

```bash
export SVN_USERNAME='CORP\rob'          # single quotes keep the backslash
export SVN_USERNAME='rob@corp.example.com'
```

## Username and password in Jenkins / CloudBees CI

### 1. Create the credential

1. Go to **Manage Jenkins** > **Credentials**, then the store and domain you use (or the folder's own credentials, to limit who can use it).
2. **Add Credentials**.
3. Kind: **Username with password**.
4. Username and password: the SVN account.
5. ID: something like `svn-creds`. This is what the pipeline refers to.
6. Description: something a teammate will recognise, like "SVN read-only account for Veracode scans".

Create the Veracode API ID and key as two **Secret text** credentials (for example `veracode-api-id` and `veracode-api-key`).

### 2. Use it in the pipeline

```groovy
withCredentials([usernamePassword(credentialsId: 'svn-creds',
                 usernameVariable: 'SVN_USERNAME',
                 passwordVariable: 'SVN_PASSWORD')]) {
  sh './veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk'
}
```

`withCredentials` sets the two environment variables only inside the block, and Jenkins masks the password if it shows up in the console log.

**Use single quotes around the `sh` step** (`sh '...'`, not `sh "..."`). With double quotes, Groovy fills in the variables before the shell sees them, which puts the password into the command Jenkins logs and shows in the process list. Jenkins warns about this as "insecure interpolation of sensitive variables".

### 3. Reusing the job's own SVN checkout credentials

If the job already checks out from SVN with a credential (for the Jenkinsfile itself, for example), you can use the same credential ID in `withCredentials`. The Subversion plugin's checkout credentials aren't passed to `sh` steps automatically.

See [jenkins-cloudbees.md](jenkins-cloudbees.md) for complete pipelines.

## Username and password from a secrets manager

The script only needs the two environment variables, so anything that can set them works.

**HashiCorp Vault:**

```bash
export SVN_USERNAME=$(vault kv get -field=username secret/ci/svn-scan)
export SVN_PASSWORD=$(vault kv get -field=password secret/ci/svn-scan)
```

**Azure Key Vault:**

```bash
export SVN_USERNAME=$(az keyvault secret show --vault-name my-vault --name svn-scan-user --query value -o tsv)
export SVN_PASSWORD=$(az keyvault secret show --vault-name my-vault --name svn-scan-pass --query value -o tsv)
```

**Kubernetes / OpenShift secret:**

```bash
oc create secret generic svn-scan-creds \
  --from-literal=SVN_USERNAME='svc-veracode' \
  --from-literal=SVN_PASSWORD='...'
```

```yaml
# in the pod spec
envFrom:
  - secretRef:
      name: svn-scan-creds
```

## Service accounts

For CI, use a dedicated SVN account rather than a person's login.

| Do | Why |
|---|---|
| Give it **read-only** access | The script never writes to SVN |
| Limit it to the repos or paths you scan | Less exposure if the password leaks |
| Name it clearly, like `svc-veracode-scan` | So SVN logs and access reviews make sense |
| Rotate the password on a schedule | Then update the Jenkins credential or secret in one place |
| Don't use it for anything else | So you know exactly what breaks when it changes |

Using a personal account means scans break when that person changes their password or leaves, and SVN logs make it look like they're reading code at 2 a.m.

## svn+ssh:// repositories

If your repo URL starts with `svn+ssh://`, SVN logs in through SSH, not with a username and password.

- Don't set `SVN_USERNAME` or `SVN_PASSWORD`.
- Set up an SSH key for the agent's user and add the public key to the SVN server.
- Put the server in `~/.ssh/known_hosts` ahead of time, since `--non-interactive` can't answer the "are you sure you want to continue connecting" prompt:

  ```bash
  ssh-keyscan svn.example.com >> ~/.ssh/known_hosts
  ```

- If the username for SSH differs from the agent's user, put it in the URL: `svn+ssh://svc-veracode@svn.example.com/repos/myapp/trunk`.
- In Jenkins, use the **SSH Agent** plugin with an SSH key credential and wrap the `sh` step in `sshagent(['svn-ssh-key']) { ... }`.

## Self-signed or internal certificates

If the SVN server uses a certificate signed by your company's internal CA, or a self-signed one, SVN refuses to connect and asks whether to trust it. With `--non-interactive` it can't ask, so you see:

```
svn: E230001: Server SSL certificate verification failed: issuer is not trusted
```

Pick one of these fixes, best first.

### Option 1: Trust your company CA (recommended)

Tell SVN about the CA certificate. Edit `~/.subversion/servers` for the user that runs the scans:

```ini
[global]
ssl-authority-files = /etc/pki/ca-trust/source/anchors/corp-root-ca.pem
```

Use a semicolon to list several files. This keeps proper certificate checking and survives the server renewing its certificate.

### Option 2: Accept the certificate once, by hand

On the agent, as the user that runs the scans:

```bash
svn info https://svn.example.com/repos/myapp/trunk
```

When asked, choose **(p)ermanently**. The certificate is saved in `~/.subversion/auth/svn.ssl.server` and later non-interactive runs use it. `--no-auth-cache` doesn't stop SVN from reading this.

This breaks when the server certificate is renewed, and has to be done on every agent and inside every container image.

### Option 3: Tell SVN to ignore specific problems (last resort)

You can add `--trust-server-cert-failures` to the `SVN_AUTH` line in the script:

```bash
SVN_AUTH=(--non-interactive --trust-server-cert-failures=unknown-ca)
```

Only list the exact problem you have (`unknown-ca`, `cn-mismatch`, `expired`, `not-yet-valid`, `other`). This turns off a security check, so someone could impersonate the SVN server and feed the scan different code. Avoid it unless you can't do options 1 or 2.

## The process list caveat

The script passes the password to SVN as a command-line argument (`--password "$SVN_PASSWORD"`). While `svn info` or `svn export` is running, other users on the same machine can see the full command, password included, with `ps -ef` or by reading `/proc`.

The same is true for the Veracode API key passed to the Java wrapper in policy mode (`-vkey`).

### When it matters

| Where it runs | Risk |
|---|---|
| Your own workstation | Low. Only you are logged in |
| Dedicated CI agent or a fresh pod per build | Low. No other users on the box |
| Shared build server where many people can log in | **Real.** Anyone logged in at the right moment could see it |

### What you can do

- **Run on dedicated agents or pods.** This is the simplest fix and is usually how CI works anyway.
- **Use `--password-from-stdin`.** SVN 1.10 and later can read the password from standard input instead of the command line. That needs a small change to the script, since it calls `svn` twice. Something like:

  ```bash
  svn_run() {
    if [[ -n "${SVN_USERNAME:-}" ]]; then
      printf '%s' "${SVN_PASSWORD:-}" | svn --non-interactive --no-auth-cache \
        --username "$SVN_USERNAME" --password-from-stdin "$@"
    else
      svn --non-interactive "$@"
    fi
  }
  ```

  then replacing `svn info "${SVN_AUTH[@]}" ...` and `svn export "${SVN_AUTH[@]}" ...` with `svn_run info ...` and `svn_run export ...`. Check `svn --version` on your agents first.
- **For the Veracode key**, the Java wrapper can read credentials from `~/.veracode/credentials` instead of `-vid`/`-vkey`. Write that file with `chmod 600` at the start of the job and delete it at the end.

## Checklist

Before putting a new SVN repo into CI:

- [ ] `svn info <url>` works from the agent, as the user that runs the job
- [ ] The account has read access to the URL and any `svn:externals` it pulls in
- [ ] Credentials come from the CI secret store, not the job definition
- [ ] The `sh` step uses single quotes in the Jenkinsfile
- [ ] Certificate trust is set up (CA file or accepted certificate) if the server uses an internal cert
- [ ] For `svn+ssh://`, the SSH key is loaded and the host is in `known_hosts`
- [ ] You know who owns the service account and when its password rotates
