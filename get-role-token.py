#!/usr/bin/env python

import socket
import json
import sys
import os
import re
from subprocess import Popen, PIPE
from pprint import pprint

def run_shell(cmd):
  p = Popen(cmd, stdout=PIPE)
  stdout, stderr = p.communicate()
  if p.returncode != 0:
    sys.exit()
  return stdout

usage = "Usage: get-role-token <role> <mfa-token>"
role = sys.argv[1] if len(sys.argv) > 1 else sys.exit(usage)
token = sys.argv[2] if len(sys.argv) > 2 else sys.exit(usage)

user = json.loads(run_shell(["aws", "iam", "get-user"]))
match = re.compile("arn\:aws\:iam\:\:(\d+):.*").match(user["User"]["Arn"])
account_number = match.group(1)

token = json.loads(run_shell(["aws", "sts", "assume-role",
                              "--role-arn", "arn:aws:iam::{}:role/{}".format(account_number, role),
                              "--role-session-name", "cli.user-{}".format(user["User"]["UserName"]),
                              "--serial-number", "arn:aws:iam::{}:mfa/{}".format(account_number, user["User"]["UserName"]),
                              "--token-code", "{}".format(token)]))

print("export AWS_ACCESS_KEY_ID={}".format(token["Credentials"]["AccessKeyId"]))
print("export AWS_SECRET_ACCESS_KEY={}".format(token["Credentials"]["SecretAccessKey"]))
print("export AWS_SESSION_TOKEN={}".format(token["Credentials"]["SessionToken"]))
print("export AWS_SECURITY_TOKEN={}".format(token["Credentials"]["SessionToken"]))
print("export AWS_ROLE_EXPIRATION={}".format(token["Credentials"]["Expiration"]))
print("export AWS_ROLE_NAME={}".format(role))

