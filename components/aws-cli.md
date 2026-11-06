# AWS CLI

Phase 07-components, shared by workstation and worker hosts, can install Amazon's AWS CLI v2 bundle.

Setting component_aws_cli to yes selects v2. Setting it to no disables v2 installation and checks. When unset, it inherits group_dev_cloud, preserving current behavior. A worker with the cloud group off, such as control VM 103, can select v2 alone without gcloud or the cloud apt group.

While v2 is selected, setup-kit removes the apt awscli v1 package if present. Apt wanted-package selection and independent verification skip that package, preventing repeated v1 reinstall and removal. When v2 is off, worker apt v1 selection stays unchanged, and any existing v2 bundle stays installed.

The installer downloads the x86_64 or aarch64 bundle from https://awscli.amazonaws.com/awscli-exe-linux-<arch>.zip to a temporary directory, unzips it, and runs the vendor installer in update mode. Default location: /usr/local/bin/aws. Check mode reports what would run and installs nothing. Failures are logged. Fix the cause and rerun installation.

Full verification requires version 2.x only while the switch is on. Version 2 is required for IAM Identity Center SSO sessions. Provisioning does not log in, seed credentials, pin releases, or set up shell completion.

Vendor guide: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
