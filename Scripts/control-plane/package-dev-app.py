#!/usr/bin/env python3
"""Wrap a signed Chromium review app for isolated launches from Finder."""
import argparse
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

LAUNCHER = r'''
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSURL *engineURL = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/CrestEngine.app"];
        NSBundle *engine = [NSBundle bundleWithURL:engineURL];
        NSString *executable = engine.executablePath;
        NSString *profile = [bundle objectForInfoDictionaryKey:@"CrestDevProfile"];
        if (!executable || !profile) return 1;
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
        NSURL *root = [[support URLByAppendingPathComponent:@"Crest Dev"] URLByAppendingPathComponent:profile];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES
                                                     attributes:nil error:&error]) return 1;
        NSString *data = [[root URLByAppendingPathComponent:@"Chromium"] path];
        setenv("CREST_ISOLATED_SESSION", "1", 1);
        setenv("CREST_ISOLATED_PERSISTENCE_ID", profile.UTF8String, 1);
        unsetenv("CREST_ISOLATED_CLOUD_SYNC_ID");
        NSString *dataArgument = [@"--user-data-dir=" stringByAppendingString:data];
        char *arguments[] = {(char *)executable.fileSystemRepresentation,
                             "--crest-control-plane", (char *)dataArgument.UTF8String, NULL};
        execv(arguments[0], arguments);
        perror("Crest Dev could not start");
        return 1;
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--signing-identity", required=True)
    parser.add_argument("--personal", action="store_true", help="Ad-hoc sign a personal test launcher")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", args.profile):
        parser.error("Use a unique lowercase profile of at most 48 characters")
    if not args.output.is_absolute() or args.output.exists() or args.output.suffix != ".app":
        parser.error("Output must be a new absolute .app path")
    if args.personal and args.signing_identity != "-":
        parser.error("Personal signing requires --signing-identity=-")
    if not args.personal and args.signing_identity.strip() in ("", "-"):
        parser.error("A Developer ID signing identity is required")
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    resources = args.app / "Contents/Resources"
    if (info["CFBundleIdentifier"] != "com.pauldavis.crest.control-plane.chromium"
            or not (resources / "Crest-Isolated-Experiment").is_file()
            or (resources / "Crest-Native-Host").exists()
            or not (args.app / "Contents/Frameworks/CrestChromiumUI.framework").is_dir()):
        parser.error("Provide an isolated Chromium review package, never the installed product")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
    contents = args.output / "Contents"
    for directory in ("MacOS", "Helpers", "Resources"):
        (contents / directory).mkdir(parents=True, exist_ok=True)
    subprocess.run(["ditto", str(args.app), str(contents / "Helpers/CrestEngine.app")], check=True)
    shutil.copy2(resources / "Crest.icns", contents / "Resources/Crest.icns")
    launcher_info = {
        "CFBundleIdentifier": "com.pauldavis.crest.dev-launcher." + args.profile,
        "CFBundleExecutable": "CrestDev",
        "CFBundlePackageType": "APPL",
        "CFBundleDisplayName": info["CFBundleDisplayName"],
        "CFBundleName": info["CFBundleName"],
        "CFBundleShortVersionString": info["CFBundleShortVersionString"],
        "CFBundleVersion": info["CFBundleVersion"],
        "LSMinimumSystemVersion": info["LSMinimumSystemVersion"],
        "CFBundleIconFile": "Crest.icns",
        "CrestDevProfile": args.profile,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(launcher_info))
    with tempfile.TemporaryDirectory(prefix="crest-dev-launcher-") as temporary:
        source = Path(temporary) / "launcher.m"
        source.write_text(LAUNCHER)
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        "-mmacosx-version-min=" + info["LSMinimumSystemVersion"], "-framework", "Foundation",
                        str(source), "-o", str(contents / "MacOS/CrestDev")], check=True)
    signing = ["codesign", "--force", "--sign", args.signing_identity]
    signing += ["--timestamp=none"] if args.personal else ["--options", "runtime", "--timestamp"]
    subprocess.run(signing + [str(args.output)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.output)], check=True)


if __name__ == "__main__":
    main()
