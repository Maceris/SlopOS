"""
Makes the TLS boot tests' test authority (decisions/0188, 13f), with Python's cryptography package:

    python -I tools/tls_peers/make_authority.py

A root, P-256, which boot.py puts in the boot disk's trust store, signs two intermediates, one P-256 and one RSA, which
sign the leaves tools/boot.py's TLS peer serves, each chosen by the name the client asks for (SNI):

- rsa.slopos.test: an RSA 2048 leaf, under the RSA intermediate;
- ecdsa.slopos.test: a P-256 leaf, under the P-256 intermediate;
- wrong.slopos.test: a valid leaf, but for other.slopos.test;
- expired.slopos.test: a leaf that expired at 2021-01-01;
- stranger.slopos.test: a leaf from another root, which isn't trusted.

And machine.slopos.test's P-256 chain and key, SlopOS's own server's identity, which test_network serves on port 443
and boot.py's client checks against the root: written to src/tests/test_network/identity.hsc as constants.

Every certificate is valid from 2025-01-01 to 2125-01-01 but the expired one. Keys are made afresh each run, so every
file changes whole. They're test keys, committed; nothing trusts this root but a test's disk.
"""

import datetime
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

HERE = Path(__file__).parent
IDENTITY = HERE.parent.parent / "src" / "tests" / "test_network" / "identity.hsc"
START = datetime.datetime(2025, 1, 1, tzinfo=datetime.timezone.utc)
END = datetime.datetime(2125, 1, 1, tzinfo=datetime.timezone.utc)


def name(common):
    return x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, "SlopOS TLS Test"), x509.NameAttribute(NameOID.COMMON_NAME, common)])


def certificate(subject, key, issuer_name, issuer_key, ca=False, names=None, start=START, end=END):
    builder = (x509.CertificateBuilder().subject_name(name(subject)).issuer_name(issuer_name).public_key(key.public_key())
               .serial_number(x509.random_serial_number()).not_valid_before(start).not_valid_after(end)
               .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    usage = dict(digital_signature=not ca, content_commitment=False, key_encipherment=False, data_encipherment=False,
                 key_agreement=False, key_cert_sign=ca, crl_sign=ca, encipher_only=False, decipher_only=False)
    builder = builder.add_extension(x509.KeyUsage(**usage), critical=True)
    # Key identifiers, which strict verifiers, Python's among them, require
    builder = builder.add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
    builder = builder.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()), critical=False)
    if not ca:
        builder = builder.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    if names:
        builder = builder.add_extension(x509.SubjectAlternativeName([x509.DNSName(each) for each in names]), critical=False)
    return builder.sign(issuer_key, hashes.SHA256())


def pem(*certificates):
    return b"".join(each.public_bytes(serialization.Encoding.PEM) for each in certificates)


def key_pem(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def der(each):
    return each.public_bytes(serialization.Encoding.DER)


root_key = ec.generate_private_key(ec.SECP256R1())
root = certificate("SlopOS TLS Test Root", root_key, name("SlopOS TLS Test Root"), root_key, ca=True)
ec_middle_key = ec.generate_private_key(ec.SECP256R1())
ec_middle = certificate("SlopOS TLS Test P-256 Intermediate", ec_middle_key, root.subject, root_key, ca=True)
rsa_middle_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
rsa_middle = certificate("SlopOS TLS Test RSA Intermediate", rsa_middle_key, root.subject, root_key, ca=True)
other_key = ec.generate_private_key(ec.SECP256R1())
other_root = certificate("SlopOS TLS Unknown Root", other_key, name("SlopOS TLS Unknown Root"), other_key, ca=True)

peers = {}
rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
peers["rsa"] = (rsa_key, [certificate("rsa.slopos.test", rsa_key, rsa_middle.subject, rsa_middle_key, names=["rsa.slopos.test"]), rsa_middle])
ecdsa_key = ec.generate_private_key(ec.SECP256R1())
peers["ecdsa"] = (ecdsa_key, [certificate("ecdsa.slopos.test", ecdsa_key, ec_middle.subject, ec_middle_key, names=["ecdsa.slopos.test"]), ec_middle])
wrong_key = ec.generate_private_key(ec.SECP256R1())
peers["wrong"] = (wrong_key, [certificate("other.slopos.test", wrong_key, ec_middle.subject, ec_middle_key, names=["other.slopos.test"]), ec_middle])
expired_key = ec.generate_private_key(ec.SECP256R1())
peers["expired"] = (expired_key, [certificate("expired.slopos.test", expired_key, ec_middle.subject, ec_middle_key, names=["expired.slopos.test"],
                                              start=datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc),
                                              end=datetime.datetime(2021, 1, 1, tzinfo=datetime.timezone.utc)), ec_middle])
stranger_key = ec.generate_private_key(ec.SECP256R1())
peers["stranger"] = (stranger_key, [certificate("stranger.slopos.test", stranger_key, other_root.subject, other_key, names=["stranger.slopos.test"])])

(HERE / "root.pem").write_bytes(pem(root))
for peer, (key, chain) in peers.items():
    (HERE / f"{peer}.pem").write_bytes(pem(*chain) + key_pem(key))

machine_key = ec.generate_private_key(ec.SECP256R1())
machine = certificate("machine.slopos.test", machine_key, ec_middle.subject, ec_middle_key, names=["machine.slopos.test"])
chain = der(machine) + der(ec_middle)
scalar = machine_key.private_numbers().private_value.to_bytes(32, "big")
out = ["package test_network", "", "/*",
       " * Made by tools/tls_peers/make_authority.py: machine.slopos.test's chain and key, test_network's TLS server's identity,",
       " * from the TLS boot tests' test authority. Don't edit; run the script again.", " */", ""]
for constant, what, data in [("MACHINE_CHAIN", "the chain machine.slopos.test is served with: its P-256 leaf, then the intermediate", chain),
                             ("MACHINE_KEY", "its leaf's P-256 secret key, a test key", scalar)]:
    out.append(f"/** {what[0].upper() + what[1:]}, {len(data)} bytes. */")
    out.append(f"{constant} :: u8.[")
    for i in range(0, len(data), 16):
        out.append("    " + ", ".join(f"0x{byte:02x}" for byte in data[i:i + 16]) + ",")
    out.append("]")
    out.append("")
IDENTITY.write_text("\n".join(out), encoding="utf-8", newline="\n")
print(f"root, {len(peers)} peers and the machine's identity")
