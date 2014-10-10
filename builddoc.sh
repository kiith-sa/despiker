#!/bin/sh
mkdir -p doc
rm -rf doc/html
cd docsrc
make html
cp -r _build/html ../doc
