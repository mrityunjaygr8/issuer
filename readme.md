### issuer

A bash script to create a cfssl, cfssljson and multirootca based TLS issuer/PKI server.
Inspired by [this blog post](https://www.mikenewswanger.com/posts/2018/kubernetes-pki/).

##### NOTE
NOT recommended for Production use as OCSP and CRL are not implmented yet


```
Usage: issuer.sh [OPTIONS]

This script creates a cfssl Public Key Issuing Server for maintaining you own PKI
This script uses cfssl, cfssljson and multirootca packages from Cloudflare's cfssl library

Options:

--target-dir            The Directory where to install the configs and the cert files. Defaults to "."
--root-cn               The CN of the root certificate. Required
--issuer-hosts          A comma separated list of the DNS name or the IP address of the hosts where this issuer can be access. DO NOT ADD "http" and "https" prefix for DNS names. Defaults to "localhost"
--api-pass              The Passowrd for the issuer API. Should be a 16 byte hex string. Can be generated using https://www.browserling.com/tools/random-hex. Required
--issuer-addr           The IP address to which the issuing server should bind to. Defaults to "0.0.0.0"
--issuer-port           The Port to which the issuing server should bind to. Defaults to "8888"
-h, --help              Show this message and exit

Example:
  issuer.sh --target-dir issuer --issuer-hosts "localhost,127.0.0.1" --api-pass="7be2e3fda569b88b"

```

### TODO

- [ ] OCSP Support
- [ ] CRL Support
- [ ] Fetch binaries
- [ ] Systemd service for the issuing server
