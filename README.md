# RenKit

A collection of tools to help you organise and use Ren'Py instances from the command line. Especially useful for headless servers.

RenKit consists of three tools:
1. `renutil` manages Ren'Py instances and takes care of installing, launching and removing them.
2. `renotize` is a macOS-exclusive tool which notarizes built distributions of Ren'Py games for macOS.
3. `renconstruct` automates the build process for Ren'Py games start to finish.

RenKit is written in Nim and compiled into standalone executables, so it's easy to use anywhere. Currently it supports the three main platforms, Windows, Linux and macOS on x86.
