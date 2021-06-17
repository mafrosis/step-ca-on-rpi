Step CA with Yubikey on Rpi
===========================

Inspired by this [blog post](https://smallstep.com/blog/build-a-tiny-ca-with-raspberry-pi-yubikey/)
and the final run cost of my [Step CA on GCP](https://github.com/mafrosis/step-ca-on-gcp) project
(30 AUD / month), I decided to simply run my CA on an existing rpi4.

The use of a Yubikey is not necessary, but does secure the key material in an offboard device isn't
easily accessible from within the docker container. The `step-ca` process of course needs to be able
to _use_ the keys to sign certificates etc, but a malicious user could not exfiltrate them as when
they're written to disk.


Install Yubikey-Manager
-----------------------

Install the C libs required for the Python install:

    sudo apt install libpcsclite-dev pcscd swig

Then install the latest via pip:

    pip install --user yubikey-manager

Check everything is working:

    ykman -v
    ykman info


Setup the Yubikey
-----------------

Reset the PIV settings on the Yubikey to their defaults:

```
> ykman piv reset
WARNING! This will delete all stored PIV data and restore factory settings. Proceed? [y/N]: y
Resetting PIV data...
Success! All PIV data have been cleared from the YubiKey.
Your YubiKey now has the default PIN, PUK and Management Key:
    PIN:    123456
    PUK:    12345678
    Management Key: 010203040506070801020304050607080102030405060708
```

[Set the PIN and the PUK](https://developers.yubico.com/yubikey-piv-manager/PIN_and_Management_Key.html):

    ykman piv access change-pin
    ykman piv access change-puk
    ykman piv access change-management-key --generate --protect


Configure Step-CA
-----------------

The following is a working example of configuring `step-ca`. The generated password will be used for
all certificate keys, and also for the "admin" provisioner.

```
> export STEPPATH=/tmp/step && mkdir -p $STEPPATH
> step ca init --name="mafro.dev CA" --provisioner=admin --dns=certs.mafro.dev --address=':443'
✔ What do you want your password to be? [leave empty and we'll generate one]:
✔ Password: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

Generating root certificate...
all done!

Generating intermediate certificate...

Generating user and host SSH certificate signing keys...
all done!

✔ Root certificate: /tmp/step/certs/root_ca.crt
✔ Root private key: /tmp/step/secrets/root_ca_key
✔ Root fingerprint: c7641ce4f91993dc3f00000000000000000000000f829c626d20fa02d89600e0
✔ Intermediate certificate: /tmp/step/certs/intermediate_ca.crt
✔ Intermediate private key: /tmp/step/secrets/intermediate_ca_key
✔ Database folder: /tmp/step/db
✔ Templates folder: /tmp/step/templates
✔ Default configuration: /tmp/step/config/defaults.json
✔ Certificate Authority configuration: /tmp/step/config/ca.json
```


Add the Step-CA certs and keys to the Yubikey
---------------------------------------------

Add both the root and intermediate into slots `82` and `83`, respectively:

    > ykman piv certificates import 82 certs/root_ca.crt
    Enter a management key [blank to use default key]:
    > ykman piv keys import 82 secrets/root_ca_key
    Enter a management key [blank to use default key]:
    Enter password to decrypt key:
    > 
    > ykman piv certificates import 83 certs/intermediate_ca.crt
    Enter a management key [blank to use default key]:
    > ykman piv keys import 83 root/secrets/intermediate_ca_key
    Enter a management key [blank to use default key]:
    Enter password to decrypt key:

The following config sets up the CA to use the Yubikey intermediate certs/keys for signing:

```
	"key": "yubikey:slot-id=83",
	"kms": {
		"type": "yubikey",
		"pin": "YUBIPIN"
	},
```

### Passing the Yubikey pin from an environment variable

All this config is committed to Github, so I certainly don't want to also include my Yubikey pin.
A solution is passing via environment variables. Step CA doesn't natively support this, so a small
bit of [jq surgery](./docker-entrypoint.sh#L6) is necessary.


Use the Yubikey to generate SSH user and host keypairs
------------------------------------------------------

Normally the `--ssh` parameter to `step ca init` is used to configure the CA server to be able to
generate SSH certs. In this case, we will instead use the Yubikey to generate the keypairs,
retaining the private component only on the Yubikey.

    > ykman piv keys generate -a ECCP256 84 certs/ssh_host_ca_key.pub
    > Enter a management key [blank to use default key]:
    > 
    > ykman piv keys generate -a ECCP256 85 certs/ssh_user_ca_key.pub
    > Enter a management key [blank to use default key]:

The following stanza is added to the CA config at `$STEPPATH/config/ca.json`:

```
  "ssh": {
    "hostKey": "yubikey:slot-id=84",
    "userKey": "yubikey:slot-id=85"
  },
```

Reference: [Enable SSH After Init](https://github.com/smallstep/certificates/discussions/400)


SSO for SSH
-----------

This section is essentially short-form instructions derived from
[smallstep.com/blog/diy-single-sign-on-for-ssh](https://smallstep.com/blog/diy-single-sign-on-for-ssh/).

Smallstep CA can issue certs for use with SSH. By configuring Google oAuth as the identity provider,
Google does the authentication for us, and `step-ca` issues the cert.


```
┌──────────┐            ┌──────────┐           ┌─ ── ── ── ── ─┐
│          │            │          │
│  Client  │────SSH────▶│  Server  │           │    Google     │
│  (macOS) │            │  (locke) │               oAuth app
│          │            │          │           │               │
└──────────┘            └──────────┘
      │                                        └─ ── ── ── ── ─┘
      │                                                ▲
      │                 ┌──────────┐                   │
    request             │          │                   │
      cert─────────────▶│    CA    │────authenticate───┘
                        │ (ringil) │
                        │          │
                        └──────────┘
```

Note: The naming convention here is to SSH from the _client_ into the _host_ server.


#### Setup the Google oAuth app

 1. Configure oAuth consent at https://console.developers.google.com/apis/credentials/consent
 2. Create an oAuth app at https://console.cloud.google.com/apis/credentials
   a. Click `Create credentials`, choosing `OAuth client ID`
   b. Select `Desktop app` as application type
   c. Retain your client ID and client secret


#### Configure the CA to support this OIDC app

Next, we must configure the CA with a new OIDC provisioner (named "Google") using above secrets. The
`--domain` parameter is your Google SSO domain name.

```
> step ca provisioner add Google --type=OIDC --ssh \
    --client-id "$OIDC_CLIENT_ID" \
    --client-secret "$OIDC_CLIENT_SECRET" \
    --configuration-endpoint 'https://accounts.google.com/.well-known/openid-configuration' \
    --domain mafro.net
Success! Your `step-ca` config has been updated. To pick up the new configuration SIGHUP (kill -1 <pid>) or restart the step-ca process.
```


#### Create trust relationship between host server and our CA

Next our CA needs to trust an identity document provided by the host system. In the blog post,
the host is an AWS EC2 instance which provides its instance identity to the CA server, and is trusted
via the Amazon signature of the AWS account ID (see [script here](https://gist.github.com/tashian/fde43668cbf6e3227fb13ef51db650b8)).

On the host server, install the [Smallstep CLI tools](#install-smallstep-cli). Next, bootstrap the
`step` client as usual:

```
> FINGERPRINT=$(step certificate fingerprint root_ca.crt)
> step ca bootstrap --ca-url https://ringil --fingerprint $FINGERPRINT
The root certificate has been saved in $HOME/.step/certs/root_ca.crt.
Your configuration has been saved in $HOME/.step/config/defaults.json.
```

Generate a certificate and configure `sshd` to use it. Run the following as root, so it's possible
to write `/etc/ssh`.

In the following example, the host server is named `locke`. The steps are:

1. Generate a token with the `admin` provisioner
2. Inspect the token for your amusement

```
> TOKEN=$(step ca token $(hostname) --ssh --host --provisioner admin)
✔ Provisioner: admin (JWK) [kid: ydABxIT07b0000000000000000000000nGYFRfEGmNA]
✔ Please enter the password to decrypt the provisioner key:
> echo $TOKEN | step crypto jwt inspect --insecure
{
  "header": {
    "alg": "ES256",
    "kid": "ydABxIT07bl-G9jSxfCB45pxNylrKitsnGYFRfEGmNA",
    "typ": "JWT"
  },
  "payload": {
    "aud": "https://ringil:8443/1.0/ssh/sign",
    "exp": 1618046362,
    "iat": 1618046062,
    "iss": "admin",
    "jti": "776b2fce13c90b675f0a1f55712eee80f2504f5f6d4723e0a4fd80e5d35fde40",
    "nbf": 1618046062,
    "sha": "b07c800d7bf36422bd7da01fc2db11efebaafdd5b83092ff82136e75a6d033f9",
    "step": {
      "ssh": {
        "certType": "host",
        "keyID": "locke",
        "principals": [],
        "validAfter": "",
        "validBefore": ""
      }
    },
    "sub": "locke"
  },
  "signature": "E-b6SIaN9atMMo-ICdnoUCjQWMLYuJxkVuB5dBDGjxtzKpPyC-ydnLH5qYV9TTss7MgA2tciMNi9ka-PJ0LNqg"
}
> step ssh certificate $(hostname) /etc/ssh/ssh_host_ecdsa_key.pub --host --sign --provisioner admin --principal $(hostname) --token $TOKEN
✔ CA: https://ringil:8443
✔ Would you like to overwrite /etc/ssh/ssh_host_ecdsa_key-cert.pub [y/n]: y
✔ Certificate: /etc/ssh/ssh_host_ecdsa_key-cert.pub
> step ssh config --host --set Certificate=ssh_host_ecdsa_key-cert.pub --set Key=ssh_host_ecdsa_key
✔ /etc/ssh/sshd_config
✔ /etc/ssh/ca.pub
> systemctl restart sshd
```

### Setup the client to use SSH via OIDC

The following steps are run on the _client_ system, which is connecting to the host configured above.

```
> FINGERPRINT=$(step certificate fingerprint root_ca.crt)
> step ca bootstrap --ca-url https://ringil --fingerprint $FINGERPRINT
The root certificate has been saved in /Users/blackm/.step/certs/root_ca.crt.
Your configuration has been saved in /Users/blackm/.step/config/defaults.json.
> step ssh config
✔ /Users/mafro/.ssh/config
✔ /Users/mafro/.step/ssh/config
✔ /Users/mafro/.step/ssh/known_hosts
```

Configure your SSH client config such that step is used to generate the SSH certificate on demand:

```
> cat ~/.ssh/config
Host locke
    User pi
    UserKnownHostsFile /Users/blackm/.step/ssh/known_hosts
    ProxyCommand step ssh proxycommand %r %h %p --provisioner Google
```

The `Google` provisioner is the OIDC one created at the beginning.

Now, using this configuration is as simple as `ssh locke`, and the OIDC flow is triggered:

```
> ssh locke
✔ Provisioner: Google (OIDC) [client: 824164598483-frmggjqidnm16kjob9ud8a6a6ahvub1v.apps.googleusercontent.com]
Your default web browser has been opened to visit:

https://accounts.google.com/o/oauth2/v2/auth?<snip>

✔ CA: https://ringil:8443
Linux locke 5.10.17-v7l+ #1414 SMP Fri Apr 30 13:20:47 BST 2021 armv7l

The programs included with the Debian GNU/Linux system are free software;
the exact distribution terms for each program are described in the
individual files in /usr/share/doc/*/copyright.

Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent
permitted by applicable law.
Last login: Thu Jun 17 06:07:51 2021 from 192.168.1.139
pi@locke:~ >
```

If you wanted to have a peek at your SSH certificate, as provisioned by your CA:

```
> step ssh list --raw | step ssh inspect
-:
    Type: ecdsa-sha2-nistp256-cert-v01@openssh.com user certificate
    Public key: ECDSA-CERT SHA256:1p9Ux0LVclOe3wFH9ISo+eUiqoAi/CoK7bE/VSdf2r0
    Signing CA: ECDSA SHA256:WoobT5Uoi8cddLhcxILd5eLoPiq27iEaVCDV/oL/B6I
    Key ID: "m@mafro.net"
    Serial: 8826815887645788865
    Valid: from 2021-06-17T05:44:17 to 2021-06-17T21:44:17
    Principals:
        m
        m@mafro.net
        mafro
        pi
    Critical Options: (none)
    Extensions:
        permit-agent-forwarding
        permit-port-forwarding
        permit-pty
        permit-user-rc
        permit-X11-forwarding
```


#### References for oAuth

- https://smallstep.com/blog/diy-single-sign-on-for-ssh/
- https://github.com/smallstep/certificates/blob/master/docs/provisioners.md#oidc


Configure an SSH template with custom principals
------------------------------------------------

When using the [OIDC provisioner](https://github.com/smallstep/certificates/blob/master/docs/provisioners.md#oidc)
to issue SSH certs, you are limited to only issuing certs with a principal which matches the email
of the OIDC identity - eg. if your email is `bob@example.com`, then the principals on your cert will
be `bob` and `bob@example.com`.

This is fine if you're logging into a server as `bob`, using an OIDC identity of `bob@example.com`.
It doesn't work if you're, say, logging in as user `pi`, using an OIDC identity of `mafro@example.com`.

This can be solved using [templated SSH certs](https://smallstep.com/blog/clever-uses-of-ssh-certificate-templates)!

Modify the `principals` field of an [SSH user template](./step-config/templates/ssh/mafro.tpl), and
update the CA config at `$STEPPATH/config/ca.json` to include the following to the `OIDC`
provisioner:

```
	"options": {
		"ssh": {
			"templateFile": "templates/ssh/mafro.tpl"
		}
	}
```


Cross-compile for armv6
-----------------------

Smallstep doesn't distribute a binary for Raspberry Pi Zero armv6 architecture. Use the following
commands to build on macOS. You could build on Raspbian, but the golang version in apt was 1.11, and
too old to build `step` at time of writing.

```
git clone --branch=v0.15.14 https://github.com/smallstep/cli.git /tmp/step-cli
cd /tmp/step-cli
GOOS=linux GOARCH=arm GOARM=6 make build
tar czf step-0.15.14-armv6.tar.gz -C bin step
mv step-0.15.14-armv6.tar.gz ~
```
