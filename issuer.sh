#!/bin/bash 
readonly SCRIPT_NAME="$(basename "$0")"

function ensure_binaries_accessible {
    if ! [ -x "$(command -v cfssl)" ]; then
        log_error "CFSSL is not installed"
        exit 1
    fi

    if ! [ -x "$(command -v cfssljson)" ]; then
        log_error "CFSSLJSON is not installed"
        exit 1
    fi
    if ! [ -x "$(command -v multirootca)" ]; then
        log_error "multirootca is not installed"
        exit 1
    fi

}

# Taken from: https://github.com/hashicorp/terraform-aws-consul/blob/master/modules/install-consul/install-consul
function log {
  local -r level="$1"
  local -r message="$2"
  local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "${timestamp} [${level}] [$SCRIPT_NAME] ${message}"
}

function log_info {
  local -r message="$1"
  log "INFO" "$message"
}

function log_warn {
  local -r message="$1"
  log "WARN" "$message"
}

function log_error {
  local -r message="$1"
  log "ERROR" "$message"
}

function assert_not_empty {
  local -r arg_name="$1"
  local -r arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function create_csr_files {
    local readonly ROOT_CN="$1"
    local ISSUER_HOSTS=""
    # taken from https://stackoverflow.com/a/10586169
    IFS=',' read -r -a ISSUER_HOSTS <<< "$2"

    cat <<EOL > "./root.csr.json"
{
    "CN": "$ROOT_CN",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "IN",
            "L": "Pune",
            "O": "MGR8",
            "OU": "PKI party",
            "ST": "Maharashtra"
        }
    ]
}
EOL
    cat <<EOL > "./intermediate.csr.json"
{
    "CN": "$ROOT_CN intermediate CA",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "IN",
            "L": "Pune",
            "O": "MGR8",
            "OU": "PKI party",
            "ST": "Maharashtra"
        }
    ]
}
EOL

    # this heredoc uses Method 3a described in this answer
    # https://stackoverflow.com/a/53839433
    cat <<EOL > "./issuer.csr.json"
{
    "hosts": [
$(delim=""; for item in "${ISSUER_HOSTS[@]}"; do printf "%s" "$delim\"$item\""; delim=","; done; echo)
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "IN",
            "L": "Pune",
            "O": "MGR8",
            "OU": "PKI party",
            "ST": "Maharashtra"
        }
    ]
}
EOL
}

function create_config_file {
    local readonly API_PASS="$1"
    cat <<EOL > "./server.config.json"
{
	"signing": {
		"default": {
			"expiry": "26280h",
			"usages": [
				"signing",
				"key encipherment",
				"client auth",
                "server auth"
			]
		},
		"profiles": {
			"intermediate": {
				"usages": [
					"cert sign",
					"crl sign"
				],
				"expiry": "26280h",
				"ca_constraint": {
					"is_ca": true
				}
			}
		}
	}
}
EOL

    cat <<EOL > "./issuer.config.json"
{
    "signing": {
        "default": {
            "usages": [
                "signing",
                "key encipherment",
                "client auth",
                "server auth"
            ],
            "expiry": "26280h",
            "auth_key": "key"
        }
    },
    "auth_keys": {
        "key": {
            "key": "$API_PASS",
            "type": "standard"
        }
    }
}
EOL
}

# taken from https://stackoverflow.com/a/7662661
function hex_string_is_valid {
    case $1 in
      ( *[!0-9A-Fa-f]* | "" ) return 1 ;;
      ( * )                
        case ${#1} in
          ( 16 ) return 0 ;;
          ( * )       return 1 ;;
        esac
    esac    
}

function create_multirootca_ini_file {
    cat <<EOL > "./multirootca-profile.ini"
[default]
private = file://intermediate-key.pem
certificate = intermediate.pem
config = issuer.config.json
EOL
}

function generate_issuer_certs {
    cfssl gencert -initca root.csr.json | cfssljson -bare root

    cfssl gencert -ca root.pem -ca-key root-key.pem \
        -config "server.config.json" -profile "intermediate" \
        intermediate.csr.json | cfssljson -bare intermediate

    cfssl gencert -ca intermediate.pem -ca-key intermediate-key.pem \
        -config "server.config.json" -profile "default" \
        issuer.csr.json | cfssljson -bare issuer
}

function create_multirootca_service_file {
    local  ISSUER_ADDR="$1"
    local readonly ISSUER_PORT="$2"
    local readonly TARGET_DIR="$3"


    sudo cat <<EOL > "/etc/systemd/system/issuer.service"
[Unit]
Description=PKI issuer
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
WorkingDirectory=$(get_abs_filename $TARGET_DIR)
ExecStart=$(which multirootca) -a "$ISSUER_ADDR":"$ISSUER_PORT" \
        -l default -roots multirootca-profile.ini \
        -tls-cert issuer.pem \
        -tls-key issuer-key.pem

[Install]
WantedBy=multi-user.target
EOL
}

function enable_issuer_service {
    sudo systemctl daemon-reload
    sudo systemctl enable --now issuer.service
}

# From: https://stackoverflow.com/a/21188136
function get_abs_filename {
  # $1 : relative filename
  filename=$1
  parentdir=$(dirname "${filename}")

  if [ -d "${filename}" ]; then
      echo "$(cd "${filename}" && pwd)"
  elif [ -d "${parentdir}" ]; then
    echo "$(cd "${parentdir}" && pwd)/$(basename "${filename}")"
  fi
}

function usage {
    echo 
    echo "Usage: issuer.sh [OPTIONS]"
    echo 
    echo "This script creates a cfssl Public Key Issuing Server for maintaining you own PKI"
    echo "This script uses cfssl, cfssljson and multirootca packages from Cloudflare's cfssl library"
    echo "This script will create a systemd service called issuer.service, which can then be used to manage the issuer"
    echo 
    echo "Options:"
    echo 
    echo -e "--target-dir\t\tThe Directory where to install the configs and the cert files. Defaults to \".\""
    echo -e "--root-cn\t\tThe CN of the root certificate. Required"
    echo -e "--issuer-hosts\t\tA comma separated list of the DNS name or the IP address of the hosts where this issuer can be access. DO NOT ADD \"http\" and \"https\" prefix for DNS names. Defaults to \"localhost\""
    echo -e "--api-pass\t\tThe Passowrd for the issuer API. Should be a 16 byte hex string. Can be generated using https://www.browserling.com/tools/random-hex. Required"
    echo -e "--issuer-addr\t\tThe IP address to which the issuing server should bind to. Defaults to \"0.0.0.0\""
    echo -e "--issuer-port\t\tThe Port to which the issuing server should bind to. Defaults to \"8888\""
    echo -e "-h, --help\t\tShow this message and exit"
    echo 
    echo "Example:"
    echo "  issuer.sh --target-dir issuer --issuer-hosts \"localhost,127.0.0.1\" --api-pass \"7be2e3fda569b88b\" --root-cn \"My PKI Issuer\""
    echo
}

function main {
    local TARGET_DIR="."
    local ROOT_CN=""
    local ISSUER_HOSTS="localhost"
    local API_PASS=""
    local PASS_VALID=""
    local ISSUER_ADDR="0.0.0.0"
    local ISSUER_PORT="8888"

    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in
            --target-dir)
            TARGET_DIR="$2"
            shift # past argument
            shift # past value
            ;;
            --root-cn)
            ROOT_CN="$2"
            shift
            shift
            ;;
            --issuer-hosts)
            ISSUER_HOSTS="$2"
            shift
            shift
            ;;
            --api-pass)
            API_PASS="$2"
            shift
            shift
            ;;
            --issuer-port)
            ISSUER_PORT="$2"
            shift
            shift
            ;;
            --issuer-addr)
            ISSUER_ADDR="$2"
            shift
            shift
            ;;
            -h|--help)
            usage
            exit 0
            ;;
            *)    # unknown option
            echo "Unrecognosed argument: $key"
            usage
            exit 1
            ;;
        esac
    done

    assert_not_empty "root-cn" "$ROOT_CN"
    assert_not_empty "api-pass" "$API_PASS"

    hex_string_is_valid "$API_PASS"
    PASS_VALID="$?"
    if [ "$PASS_VALID" -ne 0 ]
    then
        log_error "Improper api-ass. Please enter a 16 byte hex string"
        log_error "You can use https://www.browserling.com/tools/random-hex to generate a valid api-pass"
        usage
        exit 1
    fi

    log_info "Creating target directory, \"$TARGET_DIR\", if it does not exist"
    mkdir -p "$TARGET_DIR"
    cd "$TARGET_DIR"
    log_info "Creating the CSR files"
    create_csr_files  "$ROOT_CN" "$ISSUER_HOSTS"
    log_info "Creating the Issuer config file"
    create_config_file "$API_PASS"
    log_info "Generating Issuer Certificates"
    generate_issuer_certs
    log_info "Creating the issuer/multirootca config file"
    create_multirootca_ini_file
    log_info "Creating the issuer service file"
    create_multirootca_service_file "$ISSUER_ADDR" "$ISSUER_PORT"
    log_info "Starting the issuer service"
    enable_issuer_service
    log_info "ALL DONE"
}

main "$@"
