package main

import (
	"github.com/pulumi/pulumi-aws/sdk/v7/go/aws/lightsail"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")
		keyPairName := cfg.Require("keyPairName")

		// Lightsail instance — $3.50/month
		instance, err := lightsail.NewInstance(ctx, "hangout", &lightsail.InstanceArgs{
			AvailabilityZone: pulumi.String("us-east-1a"),
			BlueprintId:      pulumi.String("ubuntu_22_04"),
			BundleId:         pulumi.String("nano_3_0"),
			KeyPairName:      pulumi.String(keyPairName),
			Name:             pulumi.String("hangout"),
			UserData: pulumi.String(`#!/bin/bash
set -e

# Install Caddy
apt-get update -y
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy git build-essential

# Install Erlang + Elixir via asdf
apt-get install -y libssl-dev automake autoconf libncurses5-dev
git clone https://github.com/asdf-vm/asdf.git /opt/asdf --branch v0.14.0
export ASDF_DIR=/opt/asdf
. /opt/asdf/asdf.sh
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 27.2
asdf install elixir 1.17.3-otp-27
asdf global erlang 27.2
asdf global elixir 1.17.3-otp-27

# Create hangout user
useradd -m -s /bin/bash hangout
mkdir -p /opt/hangout
chown hangout:hangout /opt/hangout

echo "Setup complete. Clone repo and build manually."
`),
		})
		if err != nil {
			return err
		}

		// Static IP
		staticIp, err := lightsail.NewStaticIp(ctx, "hangout-ip", &lightsail.StaticIpArgs{
			Name: pulumi.String("hangout-ip"),
		})
		if err != nil {
			return err
		}

		_, err = lightsail.NewStaticIpAttachment(ctx, "hangout-ip-attach", &lightsail.StaticIpAttachmentArgs{
			InstanceName: instance.Name,
			StaticIpName: staticIp.Name,
		})
		if err != nil {
			return err
		}

		// Firewall — open HTTP, HTTPS, SSH, IRC TLS
		_, err = lightsail.NewInstancePublicPorts(ctx, "hangout-ports", &lightsail.InstancePublicPortsArgs{
			InstanceName: instance.Name,
			PortInfos: lightsail.InstancePublicPortsPortInfoArray{
				&lightsail.InstancePublicPortsPortInfoArgs{
					Protocol: pulumi.String("tcp"),
					FromPort: pulumi.Int(22),
					ToPort:   pulumi.Int(22),
				},
				&lightsail.InstancePublicPortsPortInfoArgs{
					Protocol: pulumi.String("tcp"),
					FromPort: pulumi.Int(80),
					ToPort:   pulumi.Int(80),
				},
				&lightsail.InstancePublicPortsPortInfoArgs{
					Protocol: pulumi.String("tcp"),
					FromPort: pulumi.Int(443),
					ToPort:   pulumi.Int(443),
				},
				&lightsail.InstancePublicPortsPortInfoArgs{
					Protocol: pulumi.String("tcp"),
					FromPort: pulumi.Int(6697),
					ToPort:   pulumi.Int(6697),
				},
			},
		})
		if err != nil {
			return err
		}

		// Outputs
		ctx.Export("instanceName", instance.Name)
		ctx.Export("staticIp", staticIp.IpAddress)

		return nil
	})
}
