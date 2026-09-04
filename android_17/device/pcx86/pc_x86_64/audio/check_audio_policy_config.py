#!/usr/bin/env python3
"""
Offline pre-boot validator for the AIDL audio HAL's audio policy config.

Reimplements on the host every check that is FATAL inside
hardware/interfaces/audio/aidl/default:
  AudioPolicyConfigXmlConverter::init()   AudioPolicyConfigXmlConverter.cpp:179
    -> convertModuleConfigToAidl()        XsdcConversion.cpp:529
      -> VALUE_OR_FATAL                   XmlConverter.h:128
        -> LOG_ALWAYS_FATAL               expected_utils.h:79  == SIGABRT

Exit 0 = the HAL would parse this. Non-zero = the HAL would abort at boot, or
would silently come up with no modules.

Usage: check_audio_policy_config.py <audio_policy_configuration.xml> <audio_policy_configuration.xsd>
"""
import os, re, sys
import xml.etree.ElementTree as ET

XI = "{http://www.w3.org/2001/XInclude}include"
VENDOR_EXT = re.compile(r"^VX_[A-Z0-9]{3,}_[_A-Z0-9]+$")
REMOVABLE = ("_USB", "_BLUETOOTH", "_HDMI", "_WIRED", "_BLE", "_HEARING_AID",
             "_DOCK", "_SPDIF", "_IP", "_LINE", "_ANLG_", "_DGTL_", "_REMOTE_SUBMIX")

errors, warnings = [], []
def err(m): errors.append(m)
def warn(m): warnings.append(m)
def sn(t): return t.split("}", 1)[1] if "}" in t else t


def xsd_enums(path):
    ns = "{http://www.w3.org/2001/XMLSchema}"
    out = {}
    for st in ET.parse(path).getroot().iter(ns + "simpleType"):
        if not st.get("name"):
            continue
        r = st.find(ns + "restriction")
        if r is None:
            continue
        vals = {e.get("value") for e in r.findall(ns + "enumeration")}
        if vals:
            out[st.get("name")] = vals
    return out


def load(path, stack=()):
    """parse + resolve xi:include the way xmlXIncludeProcess() does: the
       xi:include element is REPLACED by the included document's root element."""
    ap = os.path.abspath(path)
    if ap in stack:
        err("xi:include cycle at %s" % ap); return None
    if not os.path.isfile(ap):
        err("MISSING %s -- xmlXIncludeProcess() returns -1, generated read() "
            "returns nullopt, main.cpp iterates an EMPTY module list and logs "
            "nothing at all" % ap)
        return None
    root = ET.parse(ap).getroot()
    base = os.path.dirname(ap)
    def expand(node):
        for i, child in enumerate(list(node)):
            if child.tag == XI:
                sub = load(os.path.join(base, child.get("href")), stack + (ap,))
                idx = list(node).index(child)
                node.remove(child)
                if sub is not None:
                    node.insert(idx, sub)
            else:
                expand(child)
    expand(root)
    return root


def check_list(where, attr, raw, allowed, kind):
    """xsdc splits xs:list attributes on WHITESPACE ONLY (istringstream >> str).
       A comma fuses the values into one bogus token -> stringTo<Enum>() returns
       UNKNOWN -> toString() returns "-1" -> BAD_VALUE -> abort."""
    if raw is None:
        return
    if "," in raw:
        err('%s: %s="%s" contains a COMMA. This attribute is an xs:list; the '
            'generated parser splits on whitespace only, so the whole string '
            'becomes one token, resolves to UNKNOWN, toString() yields "-1", '
            'and the HAL aborts at XmlConverter.h:128. Separate with SPACES.'
            % (where, attr, raw))
        return
    for tok in raw.split():
        if kind == "int":
            try:
                int(tok)
            except ValueError:
                err('%s: %s token "%s" is not an integer -- the generated parser '
                    'calls std::stoll(), which throws and terminates the process'
                    % (where, attr, tok))
        elif tok not in allowed and not VENDOR_EXT.match(tok):
            err('%s: %s token "%s" is not a valid %s -- BAD_VALUE -> '
                'VALUE_OR_FATAL abort' % (where, attr, tok, kind))


def check_profiles(where, node, E):
    for p in node:
        if sn(p.tag) != "profile":
            continue
        check_list(where, "channelMasks", p.get("channelMasks"),
                   E.get("audioChannelMask", set()), "audioChannelMask")
        check_list(where, "samplingRates", p.get("samplingRates"), None, "int")
        f = p.get("format")
        if f is not None and f not in E.get("audioFormat", set()) and not VENDOR_EXT.match(f):
            err('%s: format="%s" is not a valid audio format -- BAD_VALUE at '
                'XsdcConversion.cpp:200 -> abort' % (where, f))


def main():
    if len(sys.argv) < 3:
        print(__doc__); return 2
    top, xsd = sys.argv[1], sys.argv[2]
    E = xsd_enums(xsd)
    root = load(top)
    if root is None or errors:
        return report()
    if sn(root.tag) != "audioPolicyConfiguration":
        err("root element is <%s>, not <audioPolicyConfiguration> -- read() "
            "returns nullopt and the HAL registers no modules" % sn(root.tag))
        return report()

    modules = [m for c in root.iter() if sn(c.tag) == "modules"
               for m in c if sn(m.tag) == "module"]
    if not modules:
        err("no <module> elements after xi:include expansion -- init() emits "
            "nothing, main.cpp registers no IModule, audioserver blocks forever")
        return report()

    for mod in modules:
        name = mod.get("name")
        w = "module '%s'" % name
        if name == "r_submix":
            continue                      # stored as nullptr, never converted

        dps = [c for c in mod if sn(c.tag) == "devicePorts"]
        mps = [c for c in mod if sn(c.tag) == "mixPorts"]
        if len(dps) > 1:
            err("%s: %d <devicePorts> elements; >1 is BAD_VALUE at "
                "XsdcConversion.cpp:401" % (w, len(dps)))
        if len(mps) > 1:
            err("%s: %d <mixPorts> elements; >1 is BAD_VALUE at "
                "XsdcConversion.cpp:454" % (w, len(mps)))

        names, dports = set(), {}
        for s in dps:
            for dp in s:
                if sn(dp.tag) != "devicePort":
                    continue
                tag = dp.get("tagName")
                if not tag:
                    err("%s: devicePort with empty tagName -- "
                        "NON_EMPTY_STRING_OR_FATAL, XsdcConversion.cpp:383" % w)
                    continue
                names.add(tag)
                dt = dp.get("type")
                dports[tag] = dt
                if dt not in E.get("audioDevice", set()) and not VENDOR_EXT.match(dt or ""):
                    err('%s devicePort "%s": type="%s" is not a valid device '
                        "type -- BAD_VALUE at XsdcConversion.cpp:226 -> abort"
                        % (w, tag, dt))
                if dt in ("AUDIO_DEVICE_IN_BUILTIN_MIC", "AUDIO_DEVICE_IN_BACK_MIC") \
                        and dp.get("address"):
                    warn('%s devicePort "%s": address="%s" is SILENTLY DISCARDED '
                         "-- XsdcConversion.cpp:239-243 overwrites the address of "
                         'every IN_MICROPHONE / IN_MICROPHONE_BACK with "bottom" / '
                         '"back" when connection is empty. StreamPrimary::'
                         "getCardAndDeviceId() will therefore fall back to card 0 "
                         "device 0." % (w, tag, dp.get("address")))
                check_profiles('%s devicePort "%s" profile' % (w, tag), dp, E)

        for s in mps:
            for mp in s:
                if sn(mp.tag) != "mixPort":
                    continue
                nm = mp.get("name")
                if not nm:
                    err("%s: mixPort with empty name -- NON_EMPTY_STRING_OR_FATAL, "
                        "XsdcConversion.cpp:433" % w)
                    continue
                names.add(nm)
                fl = mp.get("flags")
                if fl:
                    if "," in fl:
                        err('%s mixPort "%s": flags="%s" contains a comma; xs:list '
                            "splits on whitespace only" % (w, nm, fl))
                    for f in fl.replace(",", " ").split():
                        if f not in E.get("audioInOutFlag", set()):
                            warn('%s mixPort "%s": flag "%s" is not in the XSD '
                                 "enum; InputFlagConverter/OutputFlagConverter "
                                 "silently ignores it (not fatal)" % (w, nm, f))
                check_profiles('%s mixPort "%s" profile' % (w, nm), mp, E)

        attached = set()
        for ad in mod:
            if sn(ad.tag) == "attachedDevices":
                attached |= {i.text.strip() for i in ad if i.text}
        for a in attached:
            if a not in dports:
                err('%s: <attachedDevices> names "%s", which is not a devicePort '
                    "tagName -- BAD_VALUE at XsdcConversion.cpp:423 -> abort"
                    % (w, a))
        for tag, dt in dports.items():
            if not any(k in (dt or "") for k in REMOVABLE) and tag not in attached:
                err('%s: devicePort "%s" (type %s) has an empty connection but is '
                    "NOT listed in <attachedDevices> -- BAD_VALUE at "
                    "XsdcConversion.cpp:423 -> abort" % (w, tag, dt))

        d = mod.get("defaultOutputDevice")
        if d and d not in dports:
            warn('%s: defaultOutputDevice="%s" matches no devicePort' % (w, d))

        for rs in mod:
            if sn(rs.tag) != "routes":
                continue
            for r in rs:
                if sn(r.tag) != "route":
                    continue
                if r.get("sink") not in names:
                    err('%s: route sink "%s" is neither a device port nor a mix '
                        "port -- BAD_VALUE at XsdcConversion.cpp:474 -> abort"
                        % (w, r.get("sink")))
                for src in (r.get("sources") or "").split(","):
                    src = src.strip()
                    if src and src not in names:
                        err('%s: route source "%s" is neither a device port nor a '
                            "mix port -- BAD_VALUE at XsdcConversion.cpp:490 -> "
                            "abort" % (w, src))

    refs = {n.get("name") for n in root.iter()
            if sn(n.tag) == "reference" and n.get("name")}
    for n in root.iter():
        if sn(n.tag) == "volume" and n.get("ref") and n.get("ref") not in refs:
            err('<volume ref="%s"> has no matching <reference name="...">  -- '
                "mVolumesReferenceMap.at() throws std::out_of_range, uncaught, "
                "and the HAL aborts the first time audioserver calls "
                "getEngineConfig (AudioPolicyConfigXmlConverter.cpp:58)"
                % n.get("ref"))

    return report()


def report():
    for m in warnings:
        print("WARN : " + m)
    for m in errors:
        print("FATAL: " + m)
    if errors:
        print("\n==> %d fatal problem(s): this config would ABORT the audio HAL "
              "at boot." % len(errors))
        return 1
    print("\n==> OK: no fatal conversion path is reachable from this config."
          + ("  (%d warning(s))" % len(warnings) if warnings else ""))
    return 0


sys.exit(main())
