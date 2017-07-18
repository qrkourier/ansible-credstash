

# this file is intended to be sourced by your interactive shell runcom (e.g.,
#  ~/.bashrc)

# declare the name of the IAM role that will be assumed if not already defined
export AWS_ROLE_NAME=${AWS_ROLE_NAME:=devops}

# assign the default value unless the environment variable is defined
export AWS_IAM_CONFIG_CRYPT=${AWS_IAM_CONFIG_CRYPT:=~/.aws/assume-role-user.gpg}

# define some shell aliases
alias assume-role-ansible-vault='assume-role; ansible-vault --vault-password-file=./bin/get-vault-passphrase.sh'
alias assume-role-ansible-playbook='assume-role; ansible-playbook --vault-password-file=./bin/get-vault-passphrase.sh'
# backwards compatibility with a prior release of aws-assume-role.sh
alias become-sysops="assume-role ~/.aws/credentials.gpg"

assume-role(){
   # Assign AWS_ROLE_NAME=<IAM role name> in your shell runcom (e.g., ~/.bashrc)
   #
   # Compose your plaintext user config file (e.g., ~/.aws/assume-role-user) like
   #   export AWS_PROFILE=default
   #   export AWS_DEFAULT_PROFILE=default
   #   export AWS_ACCESS_KEY_ID=<access key id>
   #   export AWS_SECRET_ACCESS_KEY=<secret access key>
   #   export AWS_DEFAULT_REGION="<your default aws region (e.g. us-east-1)>"
   #   unset AWS_ROLE_NAME AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
   #
   # Encrypt your user config file and delete the plaintext
   #   `gpg -er $USER@example.com ~/.aws/assume-role-user && \
   #     rm -f ~/.aws/assume-role-user`
   #
   # Optionally, give the path to an encrypted file as a parameter to this
   # function (e.g., `assume-role ~/.aws/assume-role-user.gpg`

   # if path to an encrypted IAM config file was given to override the
   # environment variable and default value
   if [[ ${#@} -eq 1 ]]; then
     AWS_IAM_CONFIG_CRYPT=$1
   # if no parameters were given
   elif [[ ${#@} -gt 1 ]]; then
   # if more than one parameter was given
     echo "ERROR: assume-role() expects zero or one parameter as the path"\
          "to an encrypted IAM configuration file"
     return 1
  fi
  # if a fresh assume-role session is available then use it instead of
  # obtaining another to save time
  if [[ ! -z ${AWS_ROLE_NAME+x} && -s ~/.aws/${AWS_ROLE_NAME}-token ]]; then
    # if token file was modified within the last 60 minutes
    if [[ $(date --utc --reference ~/.aws/${AWS_ROLE_NAME}-token +%s) -gt \
      $(( $(date +%s) - 3600 )) ]]; then
      source ~/.aws/${AWS_ROLE_NAME}-token
      # calculate the difference in seconds between present time and role token expiry
      ROLETOKENVALIDSECS=$(( $(date -d $AWS_ROLE_EXPIRATION +%s) - $(date +%s) ))
      # if role token expiry is more than one minute in the future
      if [[ $ROLETOKENVALIDSECS -gt 60 ]]; then
        #echo "SUCCESS: reusing $AWS_ROLE_NAME token until $(date -d $AWS_ROLE_EXPIRATION)"
        return
      # if role token expiry is less than one minute in the future
      elif [[ $ROLETOKENVALIDSECS -gt 0 ]]; then
        echo "WARNING: $AWS_ROLE_NAME token expires in $ROLETOKENVALIDSECS"\
          "seconds"
        return
      fi
    # if token file is more than 60 minutes old
    else
      # if no fresh session token then prompt for any missing configuration
      #  then obtain a session token
      aws-iam-prompt-role-mfa
      aws-iam-assume-role
    fi
  else
    # if no fresh session token then prompt for any missing configuration
    #  then obtain a session token
    aws-iam-prompt-role-mfa
    aws-iam-assume-role
  fi
}

aws-iam-prompt-role-mfa(){
  [[ ! -z ${AWS_ROLE_NAME+x} ]] || {
    echo -n "role name: "
    read AWS_ROLE_NAME
  }
  [[ ! -z ${MFA_TOKEN_CODE+x} ]] || {
    echo -n "mfa token code: "
    read MFA_TOKEN_CODE
  }
}

aws-iam-assume-role (){
  # ensure the gpg executable is avilable in PATH
  which gpg 2>&1 > /dev/null || {
    echo 'ERROR: aws-iam-assume-role() says: '\
       "failed to find gpg in executable search PATH"
    return 1
  }
  # ensure the get-role-token.py executable is avilable in PATH
  which get-role-token.py 2>&1 > /dev/null || {
    echo 'ERROR: aws-iam-assume-role() says: '\
       "failed to find get-role-token.py in executable search PATH"
    return 1
  }
  # the role name must be set in the environment or configured in the IAM
  # configuration file or entered at the prompt provided by
  # aws-iam-prompt-role-mfa()
  [[ ! -z ${AWS_ROLE_NAME+x} ]] || {
    echo 'ERROR: aws-iam-assume-role() says: '\
       "required value not defined: AWS_ROLE_NAME"
    return 1
  }
  # the MFA OTP token code must be set in the environment or entered at the
  # prompt provided by aws-iam-prompt-role-mfa()
  [[ ! -z ${MFA_TOKEN_CODE+x} ]] || {
    echo 'ERROR: aws-iam-assume-role() says: '\
       "required value not defined: MFA_TOKEN_CODE"
    return 1
  }
  # it is necessary to drop the expired session token and assume own IAM
  # identity before obtaining a new session token via assume-role()
  aws-iam-drop-role-become-self || {
    echo 'ERROR: aws-iam-assume-role() says: '\
      "failed to decrypt and source the IAM user configuration from $AWS_IAM_CONFIG_CRYPT"
    return 1
  }
  # call AWS STS with role name and OTP and write generated shellcode to token
  # file
  get-role-token.py $AWS_ROLE_NAME $MFA_TOKEN_CODE >| ~/.aws/${AWS_ROLE_NAME}-token
  # discard one time passcode immediately after use
  unset MFA_TOKEN_CODE
  # fail if role session token file is empty or non-existent
  if [[ -s ~/.aws/${AWS_ROLE_NAME}-token ]]; then
    source ~/.aws/${AWS_ROLE_NAME}-token
  else
    echo 'ERROR: aws-iam-assume-role() says: '\
      "failed to get role session token from $(which get-role-token.py)"
    return 1
  fi
  # fail and destroy session token file if invalid
  if [[ ! -z ${AWS_ROLE_EXPIRATION+x} ]]; then
    :
    #echo "SUCCESS: assuming $AWS_ROLE_NAME until $(date -d $AWS_ROLE_EXPIRATION) (1h)"
    true
  else
    echo 'ERROR: aws-iam-assume-role() says: '\
       "expected value not defined: AWS_ROLE_EXPIRATION"
    rm -f ~/.aws/${AWS_ROLE_NAME}-token
    return 1
  fi
}

aws-iam-drop-role-become-self (){
  # populate lists of variable names for IAM user and role
  typeset -a AWS_IAM_MISS_VARS
  typeset -a AWS_IAM_USER_VARS=(
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
  )
  typeset -a AWS_IAM_ROLE_VARS=(
    AWS_SECURITY_TOKEN
    AWS_SESSION_TOKEN
    AWS_ROLE_EXPIRATION
  )
  # set IAM user and role variables to undefined
  for VAR in ${AWS_IAM_USER_VARS[*]} ${AWS_IAM_ROLE_VARS[*]}; do
    unset $VAR
  done
  [[ ! -z ${AWS_IAM_CONFIG_CRYPT+x} ]] && {
    source <(gpg -qd $AWS_IAM_CONFIG_CRYPT)
  } || {
    echo 'ERROR: aws-iam-drop-role-become-self() says: '\
      "required value AWS_IAM_CONFIG_CRYPT not defined"
    return 1
  }
  # verify that IAM user variables are defined
  for VAR in ${AWS_IAM_USER_VARS[*]}; do
    [[ ! -z $(eval echo \$${VAR}) ]] || {
      AWS_IAM_MISS_VARS+=($VAR)
    }
  done
  [[ ${#AWS_IAM_MISS_VARS[*]} -eq 0 ]] || {
    echo 'ERROR: aws-iam-drop-role-become-self() says: '\
      "required value(s) ${AWS_IAM_MISS_VARS[*]} not defined"
    return 1
  }
}

# successfully do nothing unless the default config crypt happens to exist
[[ -s $AWS_IAM_CONFIG_CRYPT ]] && {
  aws-iam-drop-role-become-self || {
    echo 'ERROR: aws-assume-role.sh says: '\
      "failed to decrypt and source the IAM user configuration from $AWS_IAM_CONFIG_CRYPT"
    return 1
  }
} || {
  # this is also
  :
}

