#!/bin/bash

mkdir -p "/tmp/github"
cp -R /acceptance/github-server/data/* /tmp/github
mkdir /tmp/github/members /tmp/github/members/{4,5,6,7}
touch /tmp/github/members/4/{nebelung,khaomanee,cheetoh,ojosazules}
touch /tmp/github/members/4/{blackmanx,russianblue,ragamuffin,mainecoon}
touch /tmp/github/members/5/{blackmanx,russianblue,ragamuffin,mainecoon}
touch /tmp/github/members/6/{nebelung,khaomanee,cheetoh,ojosazules}
touch /tmp/github/members/7/{blackmanx,russianblue}
mkdir -p /tmp/github/org/admin /tmp/github/org/member /tmp/github/pending
touch /tmp/github/org/admin/{blackmanx,ragamuffin,donskoy}
touch /tmp/github/org/member/{nebelung,khaomanee,cheetoh,ojosazules,mainecoon,chausie,cyprus,russianblue}

cd "$APP_HOME"
ruby web.rb
