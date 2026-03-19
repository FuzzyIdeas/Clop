#!/usr/bin/env python3
"""Add ClopTests test target to the Xcode project."""

import hashlib
import re
import sys
from pathlib import Path

PBXPROJ = Path("Clop.xcodeproj/project.pbxproj")

def gen_id(seed: str) -> str:
    """Generate a 24-char hex UUID from a seed string (deterministic)."""
    h = hashlib.sha256(seed.encode()).hexdigest()[:24].upper()
    return h

# Pre-generate all IDs we need
IDS = {}
seeds = [
    # File references
    "FR_ClopTests",           # ClopTests group itself (in main group)
    "FR_ClopTests_xctest",    # ClopTests.xctest product
    "FR_Fixtures",            # Fixtures folder reference
    "FR_Helpers",             # Helpers group
    "FR_UnitTests",           # UnitTests group
    "FR_IntegrationTests",    # IntegrationTests group
    "FR_TestFixtures.swift",
    "FR_TestHelpers.swift",
    "FR_BuildPipelineTests.swift",
    "FR_PipelineActionTests.swift",
    "FR_OperationLabelTests.swift",
    "FR_GSArgsTests.swift",
    "FR_VideoFilterTests.swift",
    "FR_FileNameTemplateTests.swift",
    "FR_BackupTests.swift",
    "FR_ImagePipelineTests.swift",
    "FR_VideoPipelineTests.swift",
    "FR_PDFPipelineTests.swift",
    "FR_CombinationTests.swift",
    "FR_generate_fixtures.sh",
    # Build files
    "BF_TestFixtures.swift",
    "BF_TestHelpers.swift",
    "BF_BuildPipelineTests.swift",
    "BF_PipelineActionTests.swift",
    "BF_OperationLabelTests.swift",
    "BF_GSArgsTests.swift",
    "BF_VideoFilterTests.swift",
    "BF_FileNameTemplateTests.swift",
    "BF_BackupTests.swift",
    "BF_ImagePipelineTests.swift",
    "BF_VideoPipelineTests.swift",
    "BF_PDFPipelineTests.swift",
    "BF_CombinationTests.swift",
    "BF_Fixtures",            # Copy Fixtures to Resources
    # Phases
    "PHASE_Sources",
    "PHASE_Frameworks",
    "PHASE_Resources",
    # Target
    "TARGET_ClopTests",
    # Config
    "CONFIG_Debug",
    "CONFIG_Release",
    "CONFIG_List",
    # Dependency
    "DEPENDENCY_Clop",
    "PROXY_Clop",
    # Groups
    "GRP_ClopTests",
    "GRP_Helpers",
    "GRP_UnitTests",
    "GRP_IntegrationTests",
    "GRP_Fixtures",
]
for s in seeds:
    IDS[s] = gen_id(f"ClopTests_{s}_v1")

content = PBXPROJ.read_text()

# ---------- PBXBuildFile Section ----------
swift_files = [
    ("TestFixtures.swift", "Sources"),
    ("TestHelpers.swift", "Sources"),
    ("BuildPipelineTests.swift", "Sources"),
    ("PipelineActionTests.swift", "Sources"),
    ("OperationLabelTests.swift", "Sources"),
    ("GSArgsTests.swift", "Sources"),
    ("VideoFilterTests.swift", "Sources"),
    ("FileNameTemplateTests.swift", "Sources"),
    ("BackupTests.swift", "Sources"),
    ("ImagePipelineTests.swift", "Sources"),
    ("VideoPipelineTests.swift", "Sources"),
    ("PDFPipelineTests.swift", "Sources"),
    ("CombinationTests.swift", "Sources"),
]

build_file_lines = []
for fname, phase in swift_files:
    bf_id = IDS[f"BF_{fname}"]
    fr_id = IDS[f"FR_{fname}"]
    build_file_lines.append(
        f"\t\t{bf_id} /* {fname} in {phase} */ = "
        f"{{isa = PBXBuildFile; fileRef = {fr_id} /* {fname} */; }};"
    )

# Add Fixtures folder resource
build_file_lines.append(
    f"\t\t{IDS['BF_Fixtures']} /* Fixtures in Resources */ = "
    f"{{isa = PBXBuildFile; fileRef = {IDS['FR_Fixtures']} /* Fixtures */; }};"
)

insert_point = "/* End PBXBuildFile section */"
content = content.replace(
    insert_point,
    "\n".join(build_file_lines) + "\n" + insert_point
)

# ---------- PBXContainerItemProxy ----------
proxy_block = f"""\t\t{IDS['PROXY_Clop']} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = C7AB6619288301590041BEC8 /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = C7AB6620288301590041BEC8;
\t\t\tremoteInfo = Clop;
\t\t}};"""

insert_point = "/* End PBXContainerItemProxy section */"
content = content.replace(insert_point, proxy_block + "\n" + insert_point)

# ---------- PBXFileReference Section ----------
file_ref_lines = []

# Product reference
file_ref_lines.append(
    f"\t\t{IDS['FR_ClopTests_xctest']} /* ClopTests.xctest */ = "
    f"{{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; "
    f"path = ClopTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};"
)

# Swift files
swift_file_refs = {
    "TestFixtures.swift": "Helpers/TestFixtures.swift",
    "TestHelpers.swift": "Helpers/TestHelpers.swift",
    "BuildPipelineTests.swift": "UnitTests/BuildPipelineTests.swift",
    "PipelineActionTests.swift": "UnitTests/PipelineActionTests.swift",
    "OperationLabelTests.swift": "UnitTests/OperationLabelTests.swift",
    "GSArgsTests.swift": "UnitTests/GSArgsTests.swift",
    "VideoFilterTests.swift": "UnitTests/VideoFilterTests.swift",
    "FileNameTemplateTests.swift": "UnitTests/FileNameTemplateTests.swift",
    "BackupTests.swift": "IntegrationTests/BackupTests.swift",
    "ImagePipelineTests.swift": "IntegrationTests/ImagePipelineTests.swift",
    "VideoPipelineTests.swift": "IntegrationTests/VideoPipelineTests.swift",
    "PDFPipelineTests.swift": "IntegrationTests/PDFPipelineTests.swift",
    "CombinationTests.swift": "IntegrationTests/CombinationTests.swift",
}
# These are only in subgroups, not top-level refs
# We only need the file refs themselves
for fname, relpath in swift_file_refs.items():
    fr_id = IDS[f"FR_{fname}"]
    file_ref_lines.append(
        f"\t\t{fr_id} /* {fname} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fname}; sourceTree = \"<group>\"; }};"
    )

# Fixtures folder ref
file_ref_lines.append(
    f"\t\t{IDS['FR_Fixtures']} /* Fixtures */ = "
    f"{{isa = PBXFileReference; lastKnownFileType = folder; path = Fixtures; sourceTree = \"<group>\"; }};"
)

insert_point = "/* End PBXFileReference section */"
content = content.replace(insert_point, "\n".join(file_ref_lines) + "\n" + insert_point)

# ---------- PBXFrameworksBuildPhase ----------
fw_phase = f"""\t\t{IDS['PHASE_Frameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""

insert_point = "/* End PBXFrameworksBuildPhase section */"
content = content.replace(insert_point, fw_phase + "\n" + insert_point)

# ---------- PBXGroup Section ----------
# ClopTests groups
helpers_group = f"""\t\t{IDS['GRP_Helpers']} /* Helpers */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{IDS['FR_TestFixtures.swift']} /* TestFixtures.swift */,
\t\t\t\t{IDS['FR_TestHelpers.swift']} /* TestHelpers.swift */,
\t\t\t);
\t\t\tpath = Helpers;
\t\t\tsourceTree = "<group>";
\t\t}};"""

unit_tests_group = f"""\t\t{IDS['GRP_UnitTests']} /* UnitTests */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{IDS['FR_BuildPipelineTests.swift']} /* BuildPipelineTests.swift */,
\t\t\t\t{IDS['FR_PipelineActionTests.swift']} /* PipelineActionTests.swift */,
\t\t\t\t{IDS['FR_OperationLabelTests.swift']} /* OperationLabelTests.swift */,
\t\t\t\t{IDS['FR_GSArgsTests.swift']} /* GSArgsTests.swift */,
\t\t\t\t{IDS['FR_VideoFilterTests.swift']} /* VideoFilterTests.swift */,
\t\t\t\t{IDS['FR_FileNameTemplateTests.swift']} /* FileNameTemplateTests.swift */,
\t\t\t);
\t\t\tpath = UnitTests;
\t\t\tsourceTree = "<group>";
\t\t}};"""

integration_tests_group = f"""\t\t{IDS['GRP_IntegrationTests']} /* IntegrationTests */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{IDS['FR_BackupTests.swift']} /* BackupTests.swift */,
\t\t\t\t{IDS['FR_ImagePipelineTests.swift']} /* ImagePipelineTests.swift */,
\t\t\t\t{IDS['FR_VideoPipelineTests.swift']} /* VideoPipelineTests.swift */,
\t\t\t\t{IDS['FR_PDFPipelineTests.swift']} /* PDFPipelineTests.swift */,
\t\t\t\t{IDS['FR_CombinationTests.swift']} /* CombinationTests.swift */,
\t\t\t);
\t\t\tpath = IntegrationTests;
\t\t\tsourceTree = "<group>";
\t\t}};"""

cloptests_group = f"""\t\t{IDS['GRP_ClopTests']} /* ClopTests */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{IDS['FR_Fixtures']} /* Fixtures */,
\t\t\t\t{IDS['GRP_Helpers']} /* Helpers */,
\t\t\t\t{IDS['GRP_UnitTests']} /* UnitTests */,
\t\t\t\t{IDS['GRP_IntegrationTests']} /* IntegrationTests */,
\t\t\t);
\t\t\tpath = ClopTests;
\t\t\tsourceTree = "<group>";
\t\t}};"""

insert_point = "/* End PBXGroup section */"
groups_block = "\n".join([helpers_group, unit_tests_group, integration_tests_group, cloptests_group])
content = content.replace(insert_point, groups_block + "\n" + insert_point)

# Add ClopTests group to main group children
# Main group is C7AB6618288301590041BEC8
# Insert after ClopCLI line in main group
content = content.replace(
    "\t\t\t\tC7956A402AC208DD00C0EDF2 /* ClopCLI */,",
    f"\t\t\t\tC7956A402AC208DD00C0EDF2 /* ClopCLI */,\n\t\t\t\t{IDS['GRP_ClopTests']} /* ClopTests */,"
)

# Add ClopTests.xctest to Products group
content = content.replace(
    "\t\t\t\tC71AAB212D2D8AB200CA86D9 /* Preview.app */,",
    f"\t\t\t\tC71AAB212D2D8AB200CA86D9 /* Preview.app */,\n\t\t\t\t{IDS['FR_ClopTests_xctest']} /* ClopTests.xctest */,"
)

# ---------- PBXNativeTarget ----------
source_files_list = "\n".join(
    f"\t\t\t\t{IDS[f'BF_{fname}']} /* {fname} in Sources */,"
    for fname, _ in swift_files
)

target_block = f"""\t\t{IDS['TARGET_ClopTests']} /* ClopTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {IDS['CONFIG_List']} /* Build configuration list for PBXNativeTarget "ClopTests" */;
\t\t\tbuildPhases = (
\t\t\t\t{IDS['PHASE_Sources']} /* Sources */,
\t\t\t\t{IDS['PHASE_Frameworks']} /* Frameworks */,
\t\t\t\t{IDS['PHASE_Resources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{IDS['DEPENDENCY_Clop']} /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = ClopTests;
\t\t\tproductName = ClopTests;
\t\t\tproductReference = {IDS['FR_ClopTests_xctest']} /* ClopTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};"""

insert_point = "/* End PBXNativeTarget section */"
content = content.replace(insert_point, target_block + "\n" + insert_point)

# ---------- PBXResourcesBuildPhase ----------
resources_phase = f"""\t\t{IDS['PHASE_Resources']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{IDS['BF_Fixtures']} /* Fixtures in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""

insert_point = "/* End PBXResourcesBuildPhase section */"
content = content.replace(insert_point, resources_phase + "\n" + insert_point)

# ---------- PBXSourcesBuildPhase ----------
sources_phase = f"""\t\t{IDS['PHASE_Sources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{source_files_list}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""

insert_point = "/* End PBXSourcesBuildPhase section */"
content = content.replace(insert_point, sources_phase + "\n" + insert_point)

# ---------- PBXTargetDependency ----------
dep_block = f"""\t\t{IDS['DEPENDENCY_Clop']} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = C7AB6620288301590041BEC8 /* Clop */;
\t\t\ttargetProxy = {IDS['PROXY_Clop']} /* PBXContainerItemProxy */;
\t\t}};"""

insert_point = "/* End PBXTargetDependency section */"
content = content.replace(insert_point, dep_block + "\n" + insert_point)

# ---------- XCBuildConfiguration ----------
debug_config = f"""\t\t{IDS['CONFIG_Debug']} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tDEVELOPMENT_TEAM = RDDXV84A73;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lowtechguys.ClopTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Clop.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Clop";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};"""

release_config = f"""\t\t{IDS['CONFIG_Release']} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tDEVELOPMENT_TEAM = RDDXV84A73;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lowtechguys.ClopTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Clop.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Clop";
\t\t\t}};
\t\t\tname = Release;
\t\t}};"""

insert_point = "/* End XCBuildConfiguration section */"
content = content.replace(insert_point, debug_config + "\n" + release_config + "\n" + insert_point)

# ---------- XCConfigurationList ----------
config_list = f"""\t\t{IDS['CONFIG_List']} /* Build configuration list for PBXNativeTarget "ClopTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{IDS['CONFIG_Debug']} /* Debug */,
\t\t\t\t{IDS['CONFIG_Release']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};"""

insert_point = "/* End XCConfigurationList section */"
content = content.replace(insert_point, config_list + "\n" + insert_point)

# ---------- Add target to project targets list ----------
content = content.replace(
    "\t\t\t\tC71AAADA2D2D8AB200CA86D9 /* Preview */,",
    f"\t\t\t\tC71AAADA2D2D8AB200CA86D9 /* Preview */,\n\t\t\t\t{IDS['TARGET_ClopTests']} /* ClopTests */,"
)

# ---------- Add TargetAttributes ----------
content = content.replace(
    "\t\t\t\t\tC7AB6620288301590041BEC8 = {",
    f"\t\t\t\t\t{IDS['TARGET_ClopTests']} = {{\n"
    f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
    f"\t\t\t\t\t\tTestTargetID = C7AB6620288301590041BEC8;\n"
    f"\t\t\t\t\t}};\n"
    f"\t\t\t\t\tC7AB6620288301590041BEC8 = {{"
)

# Write result
PBXPROJ.write_text(content)
print(f"Successfully modified {PBXPROJ}")
print(f"Generated {len(IDS)} UUIDs")
for key, val in sorted(IDS.items()):
    print(f"  {key}: {val}")
