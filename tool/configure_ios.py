#!/usr/bin/env python3
"""Set iOS identifiers/signing locally; never stores certificates or passwords."""
import argparse
import json
from pathlib import Path
import re

def configure(root, bundle_id, team_id=None, profile_name=None):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+', bundle_id):
        raise ValueError('Bundle ID must contain dot-separated letters, numbers, or hyphens.')
    if team_id and not re.fullmatch(r'[A-Z0-9]{10}', team_id):
        raise ValueError('Apple Team ID must be 10 uppercase letters/numbers.')
    if team_id and bundle_id.startswith(('com.example.', 'org.example.')):
        raise ValueError('Use your registered unique Bundle ID instead of the example identifier.')
    if profile_name and (not team_id or any(ord(c) < 32 for c in profile_name)):
        raise ValueError('A profile needs a Team ID and a name without control characters.')
    path = Path(root)/'ios/Runner.xcodeproj/project.pbxproj'
    source = path.read_text(encoding='utf-8')
    count = 0
    def replace(match):
        nonlocal count
        settings = match.group(1)
        if 'PRODUCT_BUNDLE_IDENTIFIER =' not in settings:
            return match.group(0)
        is_tests = '.RunnerTests;' in settings or '.RunnerTests";' in settings
        identifier = bundle_id + ('.RunnerTests' if is_tests else '')
        settings = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;', f'PRODUCT_BUNDLE_IDENTIFIER = {identifier};', settings)
        if not is_tests:
            count += 1
        if team_id:
            for key in ['DEVELOPMENT_TEAM','CODE_SIGN_STYLE','PROVISIONING_PROFILE_SPECIFIER','CODE_SIGN_IDENTITY']:
                settings = re.sub(r'^\s*'+key+r' = [^;]+;\n', '', settings, flags=re.M)
            signing = f'\n\t\t\t\tDEVELOPMENT_TEAM = {team_id};\n'
            signing += '\t\t\t\tCODE_SIGN_STYLE = '+('Manual' if profile_name and not is_tests else 'Automatic')+';\n'
            if profile_name and not is_tests:
                signing += '\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = '+json.dumps(profile_name, ensure_ascii=False)+';\n'
                signing += '\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";\n'
            settings += signing
        return 'buildSettings = {'+settings+'\n\t\t\t};'
    updated = re.sub(r'buildSettings = \{(.*?)\n\t\t\t\};', replace, source, flags=re.S)
    if count != 3:
        raise ValueError(f'Expected Debug/Profile/Release app settings; found {count}. No files changed.')
    path.write_text(updated, encoding='utf-8')
    return count

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--team-id')
    parser.add_argument('--profile-name')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        count = configure(args.root, args.bundle_id, args.team_id, args.profile_name)
    except ValueError as error:
        parser.error(str(error))
    print(f'Configured {count} iOS app build configurations; signing files were not copied.')

if __name__ == '__main__':
    main()
