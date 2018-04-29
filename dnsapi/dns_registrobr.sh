#!/usr/bin/env sh

#This file name is "dns_registrobr.sh"
#So, here must be a method dns_registrobr_add()
#Which will be called by acme.sh to add the txt record to your api system.
#returns 0 means success, otherwise error.
#
#Author: Fernando Crespo
#Report Bugs here: https://github.com/fcrespo82/acme.sh
#
########  Public functions #####################

# Export Registro.br userid and password in following variables...
#  REGISTROBR_User=username
#  REGISTROBR_Password=password
# login cookie is saved in acme account config file so userid / pw
# need to be set only when changed.

#Usage: dns_registrobr_add   _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_registrobr_add() {
  fulldomain="$1"
  txtvalue="$2"

  _info "Add TXT record using Registro.br"
  _debug "fulldomain: $fulldomain"
  _debug "txtvalue: $txtvalue"

  if [ -z "$REGISTROBR_User" ] || [ -z "$REGISTROBR_Password" ]; then
    REGISTROBR_User=""
    REGISTROBR_Password=""
    _err "You must export variables: REGISTROBR_User and REGISTROBR_Password"
  fi
  
  login_result="$(_registrobr_login "$REGISTROBR_User" "$REGISTROBR_Password")"

  _debug "COOKIE1" $COOKIE1
  _debug "COOKIE2" $COOKIE2

  _saveaccountconf REGISTROBR_User "$REGISTROBR_User"
  _saveaccountconf REGISTROBR_Password "$REGISTROBR_Password"

  # split our full domain name into two parts...

  sub_domain="$(echo "$fulldomain" | cut -d. -f -1)"

  _debug "fulldomain: $fulldomain"
  _debug "sub_domain: $sub_domain"

  LOGIN = "$(_registrobr_login "$REGISTROBR_User" "$REGISTROBR_Password")"
  

  return $?
}

#Usage: fulldomain txtvalue
#Remove the txt record after validation.
dns_registrobr_rm() {
  fulldomain="$1"
  txtvalue="$2"

  _info "Delete TXT record using Registro.br"
  _debug "fulldomain: $fulldomain"
  _debug "txtvalue: $txtvalue"

  # Need to read cookie from conf file again in case new value set
  # during login to Registro.br when TXT record was created.
  # acme.sh does not have a _readaccountconf() function
  FREEDNS_COOKIE="$(_read_conf "$ACCOUNT_CONF_PATH" "FREEDNS_COOKIE")"
  _debug "Registro.br login cookies: $FREEDNS_COOKIE"

  # Sometimes Registro.br does not return the subdomain page but rather
  # returns a page regarding becoming a premium member.  This usually
  # happens after a period of inactivity.  Immediately trying again
  # returns the correct subdomain page.  So, we will try twice to
  # load the page and obtain our TXT record.
  attempts=2
  while [ "$attempts" -gt "0" ]; do
    attempts="$(_math "$attempts" - 1)"

    htmlpage="$(_freedns_retrieve_subdomain_page "$FREEDNS_COOKIE")"
    if [ "$?" != "0" ]; then
      return 1
    fi

    subdomain_csv="$(echo "$htmlpage" | tr -d "\n\r" | _egrep_o '<form .*</form>' | sed 's/<tr>/@<tr>/g' | tr '@' '\n' | grep edit.php | grep "$fulldomain")"
    _debug3 "subdomain_csv: $subdomain_csv"

    # The above beauty ends with striping out rows that do not have an
    # href to edit.php and do not have the domain name we are looking for.
    # So all we should be left with is CSV of table of subdomains we are
    # interested in.

    # Now we have to read through this table and extract the data we need
    lines="$(echo "$subdomain_csv" | wc -l)"
    i=0
    found=0
    DNSdataid=""
    while [ "$i" -lt "$lines" ]; do
      i="$(_math "$i" + 1)"
      line="$(echo "$subdomain_csv" | sed -n "${i}p")"
      _debug3 "line: $line"
      DNSname="$(echo "$line" | _egrep_o 'edit.php.*</a>' | cut -d '>' -f 2 | cut -d '<' -f 1)"
      _debug2 "DNSname: $DNSname"
      if [ "$DNSname" = "$fulldomain" ]; then
        DNStype="$(echo "$line" | sed 's/<td/@<td/g' | tr '@' '\n' | sed -n '4p' | cut -d '>' -f 2 | cut -d '<' -f 1)"
        _debug2 "DNStype: $DNStype"
        if [ "$DNStype" = "TXT" ]; then
          DNSdataid="$(echo "$line" | _egrep_o 'data_id=.*' | cut -d = -f 2 | cut -d '>' -f 1)"
          _debug2 "DNSdataid: $DNSdataid"
          DNSvalue="$(echo "$line" | sed 's/<td/@<td/g' | tr '@' '\n' | sed -n '5p' | cut -d '>' -f 2 | cut -d '<' -f 1)"
          if _startswith "$DNSvalue" "&quot;"; then
            # remove the quotation from the start
            DNSvalue="$(echo "$DNSvalue" | cut -c 7-)"
          fi
          if _endswith "$DNSvalue" "..."; then
            # value was truncated, remove the dot dot dot from the end
            DNSvalue="$(echo "$DNSvalue" | sed 's/...$//')"
          elif _endswith "$DNSvalue" "&quot;"; then
            # else remove the closing quotation from the end
            DNSvalue="$(echo "$DNSvalue" | sed 's/......$//')"
          fi
          _debug2 "DNSvalue: $DNSvalue"

          if [ -n "$DNSdataid" ] && _startswith "$txtvalue" "$DNSvalue"; then
            # Found a match. But note... Website is truncating the
            # value field so we are only testing that part that is not 
            # truncated.  This should be accurate enough.
            _debug "Deleting TXT record for $fulldomain, $txtvalue"
            _freedns_delete_txt_record "$FREEDNS_COOKIE" "$DNSdataid"
            return $?
          fi

        fi
      fi
    done
  done

  # If we get this far we did not find a match (after two attempts)
  # Not necessarily an error, but log anyway.
  _debug3 "$subdomain_csv"
  _info "Cannot delete TXT record for $fulldomain, $txtvalue. Does not exist at Registro.br"
  return 0
}

####################  Private functions below ##################################

# usage: _registrobr_login username password
# print string "cookie=value" etc.
# returns 0 success
_registrobr_login() {
  _debug "Trying to login"
  export _H1="Accept-Language:en-US"
  username="$1"
  password="$2"

  url_token="https://registro.br/2/login"
  token_response="$(_get "$url_token")"

  _debug2 token_response "$token_response"

  token_line="$(echo "$token_response" | _egrep_o 'id="request-token".*value="(.*)".*>')"
  token="$(echo "$token_line" | _egrep_o 'value=".*" ' | cut -d ' ' -f 1 | cut -d '=' -f 2 | tr -d '"')"

  _debug token "$token"

  _H1="Request-Token: $token"

  url="https://registro.br/ajax/login"

  _debug "Login to Registro.br as user $username"

  data="{\"user\":\"$REGISTROBR_User\", \"password\":\"$REGISTROBR_Password\"}"

  login_response="$(_post "$data" "$url")"

  if [ "$?" != "0" ]; then
    _err "Registro.br login failed for user $username bad RC from _post"
    return 1
  fi

  _debug login_response "$login_response"

  cookies="$(egrep -i '^Set-Cookie.*$' "$HTTP_HEADER")"
  cookie1="$(echo "$cookies" | _head_n 1 | _egrep_o "stkey.*$")"
  cookie2="$(echo "$cookies" | _tail_n 1 | _egrep_o "aihandle.*$")"

  _debug cookie1 "$cookie1"
  _debug cookie2 "$cookie2"

  export COOKIE1="$cookie1"
  export COOKIE2="$cookie2"

  # if cookies is not empty then logon successful
  if [ -z "$cookies" ]; then
    _debug3 "htmlpage: $htmlpage"
    _err "Registro.br login failed for user $username. Check $HTTP_HEADER file"
    return 1
  fi

  return 0
}

# usage _freedns_retrieve_subdomain_page login_cookies
# echo page retrieved (html)
# returns 0 success
_freedns_retrieve_subdomain_page() {
  export _H1="Cookie:$1"
  export _H2="Accept-Language:en-US"
  url="https://freedns.afraid.org/subdomain/"

  _debug "Retrieve subdomain page from Registro.br"

  htmlpage="$(_get "$url")"

  if [ "$?" != "0" ]; then
    _err "Registro.br retrieve subdomains failed bad RC from _get"
    return 1
  elif [ -z "$htmlpage" ]; then
    _err "Registro.br returned empty subdomain page"
    return 1
  fi

  _debug3 "htmlpage: $htmlpage"

  printf "%s" "$htmlpage"
  return 0
}

# usage _freedns_add_txt_record login_cookies domain_id subdomain value
# returns 0 success
_freedns_add_txt_record() {
  export _H1="Cookie:$1"
  export _H2="Accept-Language:en-US"
  domain_id="$2"
  subdomain="$3"
  value="$(printf '%s' "$4" | _url_encode)"
  url="https://freedns.afraid.org/subdomain/save.php?step=2"

  htmlpage="$(_post "type=TXT&domain_id=$domain_id&subdomain=$subdomain&address=%22$value%22&send=Save%21" "$url")"

  if [ "$?" != "0" ]; then
    _err "Registro.br failed to add TXT record for $subdomain bad RC from _post"
    return 1
  elif ! grep "200 OK" "$HTTP_HEADER" >/dev/null; then
    _debug3 "htmlpage: $htmlpage"
    _err "Registro.br failed to add TXT record for $subdomain. Check $HTTP_HEADER file"
    return 1
  elif _contains "$htmlpage" "security code was incorrect"; then
    _debug3 "htmlpage: $htmlpage"
    _err "Registro.br failed to add TXT record for $subdomain as Registro.br requested security code"
    _err "Note that you cannot use automatic DNS validation for Registro.br public domains"
    return 1
  fi

  _debug3 "htmlpage: $htmlpage"
  _info "Added acme challenge TXT record for $fulldomain at Registro.br"
  return 0
}

# usage _freedns_delete_txt_record login_cookies data_id
# returns 0 success
_freedns_delete_txt_record() {
  export _H1="Cookie:$1"
  export _H2="Accept-Language:en-US"
  data_id="$2"
  url="https://freedns.afraid.org/subdomain/delete2.php"

  htmlheader="$(_get "$url?data_id%5B%5D=$data_id&submit=delete+selected" "onlyheader")"

  if [ "$?" != "0" ]; then
    _err "Registro.br failed to delete TXT record for $data_id bad RC from _get"
    return 1
  elif ! _contains "$htmlheader" "200 OK"; then
    _debug2 "htmlheader: $htmlheader"
    _err "Registro.br failed to delete TXT record $data_id"
    return 1
  fi

  _info "Deleted acme challenge TXT record for $fulldomain at Registro.br"
  return 0
}
