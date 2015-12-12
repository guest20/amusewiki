#!/bin/sh

# Automated installer for amusewiki

set -e

missing='no'
for command in perl cpanm fc-cache convert update-mime-database delve openssl \
               make gcc; do
    echo -n "Checking if $command is present: "
    if which $command > /dev/null; then
        echo "YES";
    else
        if [ $command == 'delve' ]; then
            echo "NO, please install xapian and the devel package"
        elif [ $command == 'make' ]; then
            echo "NO, please install build essential utils"
        else
            echo "NO, please install it"
        fi
        missing='yes'
    fi
done

if [ "$missing" != "no" ]; then
    cat <<EOF
Missing core utilities, cannot proceed. Please install them:

 - a working perl with cpanm (i.e., you can install modules)
 - fontconfig (install it before installing texlive)
 - graphicsmagick (for thumbnails) and imagemagick (for preview generation)
 - a mime-info database: shared-mime-info on debian
EOF
    exit 2
fi

echo -n "Checking header files for ssl: ";

check_headers () {
    output=`tempfile`
    cat <<'EOF'  | gcc -o $output -xc -
#include <stdio.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
main() { printf("Hello World"); }
EOF
}

if check_headers; then
    echo "OK";
else
    echo "NO, please install libssl-dev (or openssl-devel)";
    exit 2
fi

echo -n "Checking if I can install modules in my home..."

cpanm -q Text::Amuse

if which muse-quick.pl > /dev/null; then
    echo "OK, I can install Perl5 modules"
else
    cat <<"EOF"

It looks like I can't install modules. Please be sure to have this
line in your $HOME/.bashrc (or the rc file of your shell)

eval `perl -I ~/perl5/lib/perl5/ -Mlocal::lib`

Then login/logout

EOF
    exit 2
fi

echo "Installing perl modules"
cpanm -q Log::Dispatch Log::Log4perl Module::Install
cpanm -q Module::Install::Catalyst
# notably tests fail
cpanm -q -n DBD::mysql

cpanm -q --installdeps .
# assert we can modify it and patch this stuff
cpanm -q --reinstall CAM::PDF
script/patch-cam-pdf.sh

# check if I can access to the db

echo -n "Checking DB connection: "
if perl -I lib -MAmuseWikiFarm::Schema -MData::Dumper\
        -e 'AmuseWikiFarm::Schema->connect("amuse")->storage->dbh or die'; then
    echo "OK"
else
    cat <<EOF

Create a database for the application. E.g., for mysql:

  mysql> create database amuse DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci;
  mysql> grant all privileges on amuse.* to amuse@localhost identified by XXX

Or, for postgres:

Login as root.

 su - postgres
 psql
 create user amuse with password 'XXXX';
 create database amuse owner amuse;

Copy dbic.yaml.<dbtype>.example to dbic.yaml and adjust the
credentials, and chmod it to 600.

EOF
    exit 2
fi

