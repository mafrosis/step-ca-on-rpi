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
