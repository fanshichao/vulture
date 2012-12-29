#!/usr/bin/env python

import re
import subprocess

ifpath = "/sbin/ifconfig"

#get infos about running interfaces
def getIntfs():
    regex = re.compile(
        "^([\w\d:]+)\s.*\n\s*inet\s+ad{1,2}r(?:ess|):(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})",
        re.MULTILINE|re.IGNORECASE
        )
    intf={}
    for k,v in [x.groups() for x in regex.finditer(callIfconfig())]:
        intf[k]=v
    return intf

# add a virtual interface to existing interface
def addIntf(intf,ip,netmask=None,broadcast=None):
    if ":" not in intf or intf in getIntfs():
        return False
    return startIntf(intf,ip,netmask,broadcast)

# stop the given virtual interface
def stopIntf(intf):
    # interface doesnt exist or is not virtual
    if ":" not in intf or intf not in getIntfs():
        return False
    return callIfconfig([intf,"down"]) and True or False

# configure the given virtual interface
def startIntf(intf, ip, netmask=None, broadcast=None):
    if not ":" in intf:
        return None
    args = [intf, ip]
    if netmask:
        args += ["netmask",netmask]
    if broadcast:
        args += ["broadcast",broadcast]
    return callIfconfig(args) and True or False

#call ifconfig 
def callIfconfig(args=[]):
    proc = subprocess.Popen(["/usr/bin/sudo",ifpath] + args ,0 , "/usr/bin/sudo" , None , subprocess.PIPE)
    if proc.wait():
        raise Exception("failed to call ifconfig")
    return proc.stdout.read()

