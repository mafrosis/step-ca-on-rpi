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
│          │            │          │           │   oAuth app   │
└──────────┘            └──────────┘
      │                                        └─ ── ── ── ── ─┘
      │                                                ▲
      │                 ┌──────────┐                   │
    request             │          │                   │
      cert─────────────▶│    CA    │────authenticate───┘
                        │          │
                        └──────────┘
```

#### Setup the Google oAuth app

Note: The naming convention here is to SSH from the _client_ into the _host_ server.

 1. Configure oAuth consent at https://console.developers.google.com/apis/credentials/consent
 2. Create an oAuth app at https://console.cloud.google.com/apis/credentials
   a. Click `Create credentials`, choosing `OAuth client ID`
   b. Select `Desktop app` as application type
   c. Retain your client ID and client secret

#### Create trust relationship between host server and our CA

Next our CA needs to trust an identity document provided by the host system. In the blog post,
the host is an AWS EC2 instance which provides its instance identity to the CA server, and is trusted
via the Amazon signature of the AWS account ID (see [script here](https://gist.github.com/tashian/fde43668cbf6e3227fb13ef51db650b8)).

On the host server, install the [Smallstep CLI tools](#install-smallstep-cli). Next, bootstrap the
`step` client as usual:

```
> step ca bootstrap --ca-url https://ca.example.com --fingerprint $CA_FINGERPRINT
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

#### Setup the client to use SSH via OIDC

The following steps are run on the _client_ system, which is connecting to the host configured above.

```
FINGERPRINT=$(step certificate fingerprint root_ca.crt)
step ca bootstrap --ca-url https://ca.example.com --fingerprint $FINGERPRINT
step ssh list --raw | step ssh inspect
step ssh config
```

#### References for oAuth

- https://smallstep.com/blog/diy-single-sign-on-for-ssh/
- https://github.com/smallstep/certificates/blob/master/docs/provisioners.md#oidc
