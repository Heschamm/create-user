# Temporary SSH User Creation Script

This script creates temporary local SSH users on Linux-based VMs/Appliances.

## Features

* Creates a local Linux user
* Sets an account expiration date
* Supports three access profiles:

  * Read-only SSH access (recommended)
  * Limited sudo access
  * Full admin access
* Automatically configures SSH access for read-only users
* Verifies user configuration after creation
* Generates an audit log

## Usage

```bash
chmod +x create-temp-user.sh
./create-temp-user.sh
```

Follow the prompts and provide:

* Username
* Full Name
* Email Address
* Password
* Account validity period
* Access profile

## Compliance

Users should change their password after first login using:

```bash
passwd
```

## Removal

Delete a user:

```bash
userdel -r <username>
```
