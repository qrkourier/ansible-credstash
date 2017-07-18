#!/bin/bash -eu
#
# kbingham 2016: a wrapper script for credstash intended for use with Ansible to automate
# fetching the vault passphrase
#

# defaults
VERB=get

help(){
cat<<\TIP >&2

 if the file specified by "vault_password_file = <file>" in ansible.cfg or
   `ansible-playbook --vault-password-file=<file>` is executable then Ansible
   will run instead of read

 you could use this feature to fetch a credential from AWS's DynamoDB with
   fields encrypted by KMS so you don't have to type the vault password, or
 $ credstash get ansible_vault_passphrase

 call gpg to print the plaintext of a secret
 $ gpg -d ~/etc/root-oob001.gpg

TIP
}

while getopts v: OPT; do
  case $OPT in
    v) VERB="$(printf 'get -v%019d' $OPTARG)"
      ;;
  esac
done
#credstash -n arn:aws:iam::856481587094:role/devops \
credstash \
  $VERB ansible_vault_passphrase 2>/dev/null || help


