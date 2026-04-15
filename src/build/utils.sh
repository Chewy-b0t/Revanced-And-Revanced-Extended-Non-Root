#!/bin/bash

mkdir -p ./release ./download

#Setup pup for download apk files
if [ ! -x "./pup" ]; then
    wget -q -O ./pup.zip https://github.com/ericchiang/pup/releases/download/v0.4.0/pup_v0.4.0_linux_amd64.zip
    unzip -oq "./pup.zip" -d "./" > /dev/null 2>&1
fi
pup="./pup"
#Setup APKEditor for install combine split apks
if [ ! -s "./APKEditor.jar" ]; then
    wget -q -O ./APKEditor.jar https://github.com/REAndroid/APKEditor/releases/download/V1.4.7/APKEditor-1.4.7.jar
fi
APKEditor="./APKEditor.jar"
#Find lastest user_agent
user_agent=$(wget -T 15 -qO- https://www.whatismybrowser.com/guides/the-latest-user-agent/firefox | tr '\n' ' ' | sed 's#</tr>#\n#g' | grep 'Firefox (Standard)' | sed -n 's/.*<span class="code">\([^<]*Android[^<]*\)<\/span>.*/\1/p') \
|| user_agent=
[ -z "$user_agent" ] && {
  user_agent='Mozilla/5.0 (Android 16; Mobile; rv:146.0) Gecko/146.0 Firefox/146.0'
  echo "[-] Can't found lastest user-agent"
}

#################################################

# Colored output logs
green_log() {
    echo -e "\e[32m$1\e[0m"
}
red_log() {
    echo -e "\e[31m$1\e[0m"
}

#################################################

custom_fix_keystore="./src/custom-fixes.keystore"
custom_fix_alias="custom-fixes"
custom_fix_password="${CUSTOM_FIX_KEYSTORE_PASSWORD:-changeit}"

resolve_android_tool() {
    local tool_name="$1"
    local candidate
    local -a candidates=(
        "${ANDROID_BUILD_TOOLS_DIR}/${tool_name}"
        "${ANDROID_HOME}/build-tools/34.0.0/${tool_name}"
        "${ANDROID_SDK_ROOT}/build-tools/34.0.0/${tool_name}"
        "$HOME/Android/Sdk/build-tools/34.0.0/${tool_name}"
        "/usr/local/lib/android/sdk/build-tools/34.0.0/${tool_name}"
    )

    for candidate in "${candidates[@]}"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    command -v "$tool_name" 2>/dev/null || true
}

apksigner_bin="$(resolve_android_tool apksigner)"
zipalign_bin="$(resolve_android_tool zipalign)"

ensure_custom_fix_keystore() {
    if [ -f "$custom_fix_keystore" ]; then
        return 0
    fi

    green_log "[+] Generating signing keystore for custom APK fixes"
    keytool -genkeypair \
        -storetype PKCS12 \
        -keystore "$custom_fix_keystore" \
        -storepass "$custom_fix_password" \
        -keypass "$custom_fix_password" \
        -alias "$custom_fix_alias" \
        -keyalg RSA \
        -keysize 4096 \
        -sigalg SHA256withRSA \
        -validity 36500 \
        -dname "CN=Custom Fixes, OU=Codex, O=Local, L=Local, ST=Local, C=US" \
        >/dev/null 2>&1
}

resign_apk() {
    local apk="$1"

    if [ ! -x "$apksigner_bin" ]; then
        red_log "[-] apksigner not found at $apksigner_bin"
        exit 1
    fi

    ensure_custom_fix_keystore

    zip -dq "$apk" "META-INF/MANIFEST.MF" "META-INF/*.SF" "META-INF/*.RSA" "META-INF/*.DSA" >/dev/null 2>&1 || true

    if [ -x "$zipalign_bin" ]; then
        local aligned="${apk%.apk}-aligned.apk"
        rm -f "$aligned"
        "$zipalign_bin" -f -p 4 "$apk" "$aligned"
        mv -f "$aligned" "$apk"
    fi

    "$apksigner_bin" sign \
        --ks "$custom_fix_keystore" \
        --ks-key-alias "$custom_fix_alias" \
        --ks-pass "pass:$custom_fix_password" \
        --key-pass "pass:$custom_fix_password" \
        "$apk"
}

disable_youtube_watch_break() {
    local apk="$1"
    local deleted=0
    local entry
    local -a watch_break_entries=(
        "assets/mainapp_filegroup/_srs_resources_eml_bundle/watch_break_bottom_sheet_controller_ae1c37de520109e7"
        "assets/mainapp_filegroup/_srs_resources_eml_bundle/watch_break_reminder.eml-js_e8532bbd12df7300"
        "assets/mainapp_filegroup/_srs_resources_eml_bundle/watch_break_reminder_controller_module_b8b58846d7ecc800"
        "assets/mainapp_filegroup/_srs_resources_eml_bundle/watch_break_reminder_footer.eml-js_65e70bc0cd7b0779"
        "assets/mainapp_filegroup/_srs_resources_eml_bundle/watch_break_reminder_footer_controller_8b074ad6f20d22da"
        "assets/mainapp_filegroup/_srs_resources_eml_bundle/watch_break_settings_bottom_sheet.eml-js_8bb9574c6f3e202d"
    )

    green_log "[+] Removing YouTube watch break assets from $(basename "$apk")"
    for entry in "${watch_break_entries[@]}"; do
        if unzip -l "$apk" "$entry" >/dev/null 2>&1; then
            zip -dq "$apk" "$entry" >/dev/null 2>&1
            deleted=1
        fi
    done

    if [ "$deleted" -eq 1 ]; then
        resign_apk "$apk"
    else
        red_log "[-] No watch break assets were found in $(basename "$apk")"
    fi
}

postprocess_patched_apk() {
    local apk="$1"
    local app="$2"

    case "$app" in
        youtube|youtube-arm64-v8a|youtube-armeabi-v7a|youtube-x86|youtube-x86_64)
            disable_youtube_watch_break "$apk"
            ;;
    esac
}

#################################################

# Download Github assets requirement:
get_revanced_gitlab_tag() {
    local requested_tag="$1"
    local release_json

    release_json=$(wget -qO- "https://gitlab.com/api/v4/projects/revanced%2Frevanced-patches/releases") || return 1

    if [[ "$requested_tag" == "prerelease" ]]; then
        printf '%s' "$release_json" | jq -r 'map(select(.tag_name | contains("-dev."))) | .[0].tag_name // empty'
    elif [[ "$requested_tag" == "latest" ]]; then
        printf '%s' "$release_json" | jq -r 'map(select((.tag_name | contains("-dev.")) | not)) | .[0].tag_name // empty'
    else
        printf '%s\n' "$requested_tag"
    fi
}

customize_revanced_gitlab_source() {
    local source_dir="$1"

    python3 - <<PY
from pathlib import Path

check_java = Path(r"$source_dir/extensions/shared/library/src/main/java/app/revanced/extension/shared/checks/Check.java")
text = check_java.read_text()
old_should_run = """    static boolean shouldRun() {\n        return BaseSettings.CHECK_ENVIRONMENT_WARNINGS_ISSUED.get()\n                < NUMBER_OF_TIMES_TO_IGNORE_WARNING_BEFORE_DISABLING;\n    }\n"""
new_should_run = """    static boolean shouldRun() {\n        return false;\n    }\n"""
if old_should_run not in text:
    raise SystemExit("expected Check.shouldRun block not found")
check_java.write_text(text.replace(old_should_run, new_should_run, 1))

env_java = Path(r"$source_dir/extensions/shared/library/src/main/java/app/revanced/extension/shared/checks/CheckEnvironmentPatch.java")
text = env_java.read_text()
if "import java.io.File;\n" not in text:
    marker = "import java.nio.charset.StandardCharsets;\n"
    if marker not in text:
        raise SystemExit("expected import marker not found in CheckEnvironmentPatch.java")
    text = text.replace(marker, marker + "import java.io.File;\n", 1)

old_check_method = """    public static void check(Activity context) {\n        // If the warning was already issued twice, or if the check was successful in the past,\n        // do not run the checks again.\n"""
new_check_method = """    public static void check(Activity context) {\n        suppressYouTubeReminderPreferences(context);\n\n        // If the warning was already issued twice, or if the check was successful in the past,\n        // do not run the checks again.\n"""
if old_check_method not in text:
    raise SystemExit("expected CheckEnvironmentPatch.check method header not found")
text = text.replace(old_check_method, new_check_method, 1)

helper_anchor = "    private static boolean buildFieldEqualsHash(String buildFieldName, String buildFieldValue, @Nullable String hash) {"
helper_code = """    private static void suppressYouTubeReminderPreferences(Activity context) {\n        if (context == null) {\n            return;\n        }\n\n        try {\n            File sharedPrefsDir = new File(context.getApplicationInfo().dataDir, \"shared_prefs\");\n            File[] sharedPrefsFiles = sharedPrefsDir.listFiles((dir, name) -> name.endsWith(\".xml\"));\n            if (sharedPrefsFiles == null) {\n                return;\n            }\n\n            for (File sharedPrefsFile : sharedPrefsFiles) {\n                String fileName = sharedPrefsFile.getName();\n                String prefsName = fileName.substring(0, fileName.length() - 4);\n                android.content.SharedPreferences prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE);\n                Map<String, ?> entries = prefs.getAll();\n                if (entries == null || entries.isEmpty()) {\n                    continue;\n                }\n\n                android.content.SharedPreferences.Editor editor = prefs.edit();\n                boolean changed = false;\n\n                for (Map.Entry<String, ?> entry : entries.entrySet()) {\n                    String key = entry.getKey();\n                    if (key == null) {\n                        continue;\n                    }\n\n                    Object value = entry.getValue();\n                    if (isReminderBooleanKey(key) && value instanceof Boolean) {\n                        if (((Boolean) value).booleanValue()) {\n                            editor.putBoolean(key, false);\n                            changed = true;\n                        }\n                    } else if (isReminderIntegerKey(key) && value instanceof Integer) {\n                        if (((Integer) value).intValue() != 0) {\n                            editor.putInt(key, 0);\n                            changed = true;\n                        }\n                    }\n                }\n\n                if (changed) {\n                    editor.apply();\n                    Logger.printInfo(() -> \"Disabled YouTube reminder preferences in \" + prefsName);\n                }\n            }\n        } catch (Exception ex) {\n            Logger.printException(() -> \"Failed to suppress YouTube reminder preferences\", ex);\n        }\n    }\n\n    private static boolean isReminderBooleanKey(String key) {\n        return key.equals(\"bedtime_reminder_toggle\")\n                || key.endsWith(\":bedtime_reminder_toggle\")\n                || key.endsWith(\"bollard_enabled\");\n    }\n\n    private static boolean isReminderIntegerKey(String key) {\n        return key.endsWith(\"bollard_frequency_mins\");\n    }\n\n"""
if helper_anchor not in text:
    raise SystemExit("expected helper anchor not found in CheckEnvironmentPatch.java")
if "private static void suppressYouTubeReminderPreferences(Activity context)" not in text:
    text = text.replace(helper_anchor, helper_code + helper_anchor, 1)

env_java.write_text(text)
PY
}

build_revanced_patches_from_gitlab() {
    local requested_tag="$1"
    local resolved_tag tmp_dir archive_path source_dir plugin_dir artifact
    local dest_dir="$PWD"
    local android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"

    resolved_tag=$(get_revanced_gitlab_tag "$requested_tag") || resolved_tag=""
    if [[ -z "$resolved_tag" ]]; then
        red_log "[-] Failed to resolve revanced-patches tag from GitLab"
        return 1
    fi

    tmp_dir=$(mktemp -d)
    archive_path="$tmp_dir/revanced-patches.tar.gz"
    source_dir="$tmp_dir/revanced-patches-$resolved_tag"
    plugin_dir="$tmp_dir/revanced-patches-gradle-plugin"

    local gradle_user="${GITHUB_ACTOR:-}"
    local gradle_pass="${GITHUB_TOKEN:-}"
    if [[ -z "$gradle_user" ]] && command -v gh >/dev/null 2>&1; then
        gradle_user=$(gh api user --jq '.login' 2>/dev/null || true)
    fi
    if [[ -z "$gradle_pass" ]] && command -v gh >/dev/null 2>&1; then
        gradle_pass=$(gh auth token 2>/dev/null || true)
    fi

    if [[ -z "$android_sdk" ]]; then
        for candidate in "$HOME/Android/Sdk" "$HOME/android-sdk" "/usr/local/lib/android/sdk" "/usr/lib/android-sdk" "/opt/android/sdk"; do
            if [[ -d "$candidate/platform-tools" || -d "$candidate/build-tools" ]]; then
                android_sdk="$candidate"
                break
            fi
        done
    fi

    green_log "[+] Building revanced-patches $resolved_tag from GitLab mirror"
    if ! wget -q -O "$archive_path" "https://gitlab.com/ReVanced/revanced-patches/-/archive/$resolved_tag/revanced-patches-$resolved_tag.tar.gz"; then
        red_log "[-] Failed to download revanced-patches source archive for $resolved_tag"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! tar -xzf "$archive_path" -C "$tmp_dir"; then
        red_log "[-] Failed to extract revanced-patches source archive for $resolved_tag"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! git clone --depth 1 https://github.com/ReVanced/revanced-patches-gradle-plugin.git "$plugin_dir" >/dev/null 2>&1; then
        red_log "[-] Failed to download revanced-patches Gradle plugin source"
        rm -rf "$tmp_dir"
        return 1
    fi

    python3 - <<PY >/dev/null
from pathlib import Path
settings = Path(r"$source_dir/settings.gradle.kts")
text = settings.read_text()
line = '    includeBuild("../revanced-patches-gradle-plugin")\n'
if line not in text:
    text = text.replace('pluginManagement {\n', 'pluginManagement {\n' + line, 1)
settings.write_text(text)
PY

    customize_revanced_gitlab_source "$source_dir" || {
        red_log "[-] Failed to customize revanced-patches source"
        rm -rf "$tmp_dir"
        return 1
    }

    if [[ -n "$android_sdk" ]]; then
        printf 'sdk.dir=%s\n' "$android_sdk" > "$source_dir/local.properties"
    fi

    (
        cd "$source_dir" || exit 1
        ORG_GRADLE_PROJECT_githubPackagesUsername="$gradle_user" \
        ORG_GRADLE_PROJECT_githubPackagesPassword="$gradle_pass" \
        ./gradlew --no-daemon clean :patches:buildAndroid
    ) || {
        red_log "[-] Failed to build revanced-patches $resolved_tag from GitLab mirror"
        rm -rf "$tmp_dir"
        return 1
    }

    artifact=$(find "$source_dir/patches/build/libs" -maxdepth 1 -type f -name 'patches-*.rvp' | head -n1)
    if [[ -z "$artifact" ]]; then
        red_log "[-] revanced-patches build succeeded but no .rvp artifact was found"
        rm -rf "$tmp_dir"
        return 1
    fi

    cp -f "$artifact" "$dest_dir/"
    green_log "[+] Downloading $(basename "$artifact") from revanced (GitLab mirror build)"
    rm -rf "$tmp_dir"
}

dl_gh() {
  if [ "$3" == "prerelease" ]; then
    local repo=$1
    for repo in $1 ; do
      local owner=$2 tag=$3 found=0 assets=0 downloaded=0
      releases=$(wget -qO- "https://api.github.com/repos/$owner/$repo/releases" 2>/dev/null || true)
      while read -r line; do
        if [[ $line == *"\"tag_name\":"* ]]; then
          tag_name=$(echo $line | cut -d '"' -f 4)
          if [ "$tag" == "latest" ] || [ "$tag" == "prerelease" ]; then
            found=1
          else
            found=0
          fi
        fi
        if [[ $line == *"\"prerelease\":"* ]]; then
          prerelease=$(echo $line | cut -d ' ' -f 2 | tr -d ',')
          if [ "$tag" == "prerelease" ] && [ "$prerelease" == "true" ] ; then
            found=1
          elif [ "$tag" == "prerelease" ] && [ "$prerelease" == "false" ]; then
            found=1
          fi
        fi
        if [[ $line == *"\"assets\":"* ]]; then
          if [ $found -eq 1 ]; then
            assets=1
          fi
        fi
        if [[ $line == *"\"browser_download_url\":"* ]]; then
          if [ $assets -eq 1 ]; then
            url=$(echo $line | cut -d '"' -f 4)
            if [[ $url != *.asc ]]; then
              name=$(basename "$url")
              wget -q -O "$name" "$url"
              green_log "[+] Downloading $name from $owner"
              downloaded=1
            fi
          fi
        fi
        if [[ $line == *"],"* ]]; then
          if [ $assets -eq 1 ]; then
            assets=0
            break
          fi
        fi
      done <<< "$releases"
      if [[ "$owner" == "revanced" && "$repo" == "revanced-patches" && $downloaded -eq 0 ]]; then
        build_revanced_patches_from_gitlab "$tag" || return 1
      fi
    done
  else
    for repo in $1 ; do
      local downloaded=0
      tags=$( [ "$3" == "latest" ] && echo "latest" || echo "tags/$3" )
      while read -r url names; do
        if [[ -z "$url" || -z "$names" ]]; then
          continue
        fi
        if [[ $url != *.asc ]]; then
          if [[ "$3" == "latest" && "$names" == *dev* ]]; then
            continue
          fi
          green_log "[+] Downloading $names from $2"
          wget -q -O "$names" $url
          downloaded=1
        fi
      done < <(wget -qO- "https://api.github.com/repos/$2/$repo/releases/$tags" 2>/dev/null | jq -r '.assets[]? | "\(.browser_download_url) \(.name)"')

      if [[ "$2" == "revanced" && "$repo" == "revanced-patches" && $downloaded -eq 0 ]]; then
        build_revanced_patches_from_gitlab "$3" || return 1
      fi
    done
  fi
}

#################################################

# Get patches list:
get_patches_key() {
	excludePatches=""
	includePatches=""
	excludeLinesFound=false
	includeLinesFound=false

	local patchDir="src/patches/$1"
	local cliMode=""
	local patch_name options line1 line2 num

	sed -i 's/\r$//' "$patchDir/include-patches"
	sed -i 's/\r$//' "$patchDir/exclude-patches"

	if compgen -G "morphe-cli-*.jar" > /dev/null; then
		cliMode="morphe"
	elif compgen -G "revanced-cli-*.jar" > /dev/null; then
		if [[ $(ls revanced-cli-*.jar | head -n1) =~ revanced-cli-([0-9]+) ]]; then
			num=${BASH_REMATCH[1]}
			if [ "$num" -ge 5 ]; then
				cliMode="revanced_new"
			else
				cliMode="revanced_old"
			fi
		else
			cliMode="revanced_old"
		fi
	fi

	if [[ "$cliMode" == "morphe" ]]; then
		while IFS= read -r line1 || [[ -n "$line1" ]]; do
			[[ -z "$line1" ]] && continue
			excludePatches+=" -d \"$line1\""
			excludeLinesFound=true
		done < "$patchDir/exclude-patches"

		while IFS= read -r line2 || [[ -n "$line2" ]]; do
			[[ -z "$line2" ]] && continue
			patch_name="${line2%%|*}"   # ignore options part for options.json flow
			includePatches+=" -e \"$patch_name\""
			includeLinesFound=true
		done < "$patchDir/include-patches"

	elif [[ "$cliMode" == "revanced_new" ]]; then
		while IFS= read -r line1 || [[ -n "$line1" ]]; do
			[[ -z "$line1" ]] && continue
			excludePatches+=" -d \"$line1\""
			excludeLinesFound=true
		done < "$patchDir/exclude-patches"

		while IFS= read -r line2 || [[ -n "$line2" ]]; do
			[[ -z "$line2" ]] && continue
			if [[ "$line2" == *"|"* ]]; then
				patch_name="${line2%%|*}"
				options="${line2#*|}"
				includePatches+=" -e \"${patch_name}\" ${options}"
			else
				includePatches+=" -e \"$line2\""
			fi
			includeLinesFound=true
		done < "$patchDir/include-patches"

	elif [[ "$cliMode" == "revanced_old" ]]; then
		while IFS= read -r line1 || [[ -n "$line1" ]]; do
			[[ -z "$line1" ]] && continue
			excludePatches+=" -e \"$line1\""
			excludeLinesFound=true
		done < "$patchDir/exclude-patches"

		while IFS= read -r line2 || [[ -n "$line2" ]]; do
			[[ -z "$line2" ]] && continue
			includePatches+=" -i \"$line2\""
			includeLinesFound=true
		done < "$patchDir/include-patches"
	fi

	if [ "$excludeLinesFound" = false ]; then
		excludePatches=""
	fi
	if [ "$includeLinesFound" = false ]; then
		includePatches=""
	fi

	export excludePatches
	export includePatches
}

#################################################

# Download apks files from APKMirror:
_req() {
    if [ "$2" = "-" ]; then
        wget -nv -O "$2" --header="User-Agent: $user_agent" --header="Content-Type: application/octet-stream" --header="Accept-Language: en-US,en;q=0.9" --header="Connection: keep-alive" --header="Upgrade-Insecure-Requests: 1" --header="Cache-Control: max-age=0" --header="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8" --keep-session-cookies --timeout=30 "$1" || rm -f "$2"
    else
        wget -nv -O "./download/$2" --header="User-Agent: $user_agent" --header="Content-Type: application/octet-stream" --header="Accept-Language: en-US,en;q=0.9" --header="Connection: keep-alive" --header="Upgrade-Insecure-Requests: 1" --header="Cache-Control: max-age=0" --header="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8" --keep-session-cookies --timeout=30 "$1" || rm -f "./download/$2"
    fi
}
req() {
    _req "$1" "$2"
}
dl_apk() {
	local url=$1 regexp=$2 output=$3
	if [[ -z "$4" ]] || [[ $4 == "Bundle" ]] || [[ $4 == "Bundle_extract" ]]; then
		url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n "s/.*<a[^>]*href=\"\([^\"]*\)\".*${regexp}.*/\1/p")"
	else
		url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n "s/href=\"/@/g; s;.*${regexp}.*;\1;p")"
	fi
	url="https://www.apkmirror.com$(req "$url" - | grep -oP 'class="[^"]*downloadButton[^"]*".*?href="\K[^"]+')"
   	url="https://www.apkmirror.com$(req "$url" - | grep -oP 'id="download-link".*?href="\K[^"]+')"
	#url="https://www.apkmirror.com$(req "$url" - | $pup -p --charset utf-8 'a.downloadButton attr{href}')"
   	#url="https://www.apkmirror.com$(req "$url" - | $pup -p --charset utf-8 'a#download-link attr{href}')"
	if [[ "$url" == "https://www.apkmirror.com" ]]; then
		exit 0
	fi
	req "$url" "$output"
}

# Detect compatible version from CLI patches:
detect_version() {
	if [ -z "$version" ] && [ "$lock_version" != "1" ]; then
	  for spec in "revanced-cli-|5|*.rvp" "morphe-cli-|1|*.mpp"; do
		IFS="|" read -r jar_prefix min_major patch_glob <<<"$spec"

		if [[ $(ls "${jar_prefix}"*.jar 2>/dev/null) =~ ${jar_prefix}([0-9]+) ]]; then
		  num=${BASH_REMATCH[1]}

		  if [ "$num" -ge "$min_major" ]; then
			if [[ "$jar_prefix" == "morphe-cli-" ]]; then
			  list_patches_flags="list-patches --with-packages --with-versions --with-options --patches"
			elif [ "$num" -ge 6 ]; then
			  list_patches_flags="list-patches --packages --versions --options -bp"
			else
			  list_patches_flags="list-patches --with-packages --with-versions"
			fi
			version=$(java -jar *cli*.jar $list_patches_flags $patch_glob | awk -v pkg="$1" '
			  BEGIN { found = 0; printing = 0 }
			  /^Index:/ { if (printing) exit; found = 0 }
			  /Package name: / { if ($3 == pkg) found = 1 }
			  /Compatible versions:/ { if (found) printing = 1; next }
			  printing && $1 ~ /^[0-9]+\./ { print $1 }
			' | sort -V | tail -n1)
		  else
			version=$(jq -r '[.. | objects | select(.name == "'"$1"'" and .versions != null) | .versions[]] | reverse | .[0] // ""' *.json 2>/dev/null | uniq)
		  fi
		fi

		[ -n "$version" ] && break
	  done
	fi
}

get_apk() {
	if [[ -z $5 ]]; then
		url_regexp='APK<\/span>'
	elif [[ $5 == "Bundle" ]] || [[ $5 == "Bundle_extract" ]]; then
		url_regexp='BUNDLE<\/span>'
	else
		case $5 in
			arm64-v8a) url_regexp='arm64-v8a'"[^@]*$7"''"[^@]*$6"'</div>[^@]*@\([^"]*\)' ;;
			armeabi-v7a) url_regexp='armeabi-v7a'"[^@]*$7"''"[^@]*$6"'</div>[^@]*@\([^"]*\)' ;;
			x86) url_regexp='x86'"[^@]*$7"''"[^@]*$6"'</div>[^@]*@\([^"]*\)' ;;
			x86_64) url_regexp='x86_64'"[^@]*$7"''"[^@]*$6"'</div>[^@]*@\([^"]*\)' ;;
			*) url_regexp='$5'"[^@]*$7"''"[^@]*$6"'</div>[^@]*@\([^"]*\)' ;;
		esac
	fi

	detect_version "$1"

	export version="$version"

	version=$(printf '%s\n' "$version" "$prefer_version" | sort -V | tail -n1)
	unset prefer_version

    if [[ -n "$version" ]]; then
        version=$(echo "$version" | tr -d ' ' | sed 's/\./-/g')
        green_log "[+] Downloading $3 version: $version $5 $6 $7"
        if [[ $5 == "Bundle" ]] || [[ $5 == "Bundle_extract" ]]; then
            local base_apk="$2.apkm"
        else
            local base_apk="$2.apk"
        fi
        local dl_url=$(dl_apk "https://www.apkmirror.com/apk/$4-$version-release/" \
                              "$url_regexp" \
                              "$base_apk" \
                              "$5")
        if [[ -f "./download/$base_apk" ]]; then
            green_log "[+] Successfully downloaded $2"
        else
            red_log "[-] Failed to download $2"
            exit 1
        fi
        if [[ $5 == "Bundle" ]]; then
            green_log "[+] Merge splits apk to standalone apk"
            java -jar $APKEditor m -i ./download/$2.apkm -o ./download/$2.apk > /dev/null 2>&1
        elif [[ $5 == "Bundle_extract" ]]; then
            unzip "./download/$base_apk" -d "./download/$(basename "$base_apk" .apkm)" > /dev/null 2>&1
        fi
        return 0
    fi
	local attempt=0
	while [ $attempt -lt 10 ]; do
		if [[ -z $version ]] || [ $attempt -ne 0 ]; then
			local upload_tail="?$([[ $3 = duolingo ]] && echo devcategory= || echo appcategory=)"
			version=$(req "https://www.apkmirror.com/uploads/$upload_tail$3" - | \
				$pup 'div.widget_appmanager_recentpostswidget h5 a.fontBlack text{}' | \
				grep -Evi 'alpha|beta' | \
				grep -oPi '\b\d+(\.\d+)+(?:\-\w+)?(?:\.\d+)?(?:\.\w+)?\b' | \
				sed -n "$((attempt + 1))p")
		fi
		version=$(echo "$version" | tr -d ' ' | sed 's/\./-/g')
		green_log "[+] Downloading $3 version: $version $5 $6 $7"
		if [[ $5 == "Bundle" ]] || [[ $5 == "Bundle_extract" ]]; then
			local base_apk="$2.apkm"
		else
			local base_apk="$2.apk"
		fi
		local dl_url=$(dl_apk "https://www.apkmirror.com/apk/$4-$version-release/" \
							  "$url_regexp" \
							  "$base_apk" \
							  "$5")
		if [[ -f "./download/$base_apk" ]]; then
			green_log "[+] Successfully downloaded $2"
			break
		else
			((attempt++))
			red_log "[-] Failed to download $2, trying another version"
			unset version
		fi
	done

	if [ $attempt -eq 10 ]; then
		red_log "[-] No more versions to try. Failed download"
		return 1
	fi
	if [[ $5 == "Bundle" ]]; then
		green_log "[+] Merge splits apk to standalone apk"
		java -jar $APKEditor m -i ./download/$2.apkm -o ./download/$2.apk > /dev/null 2>&1
	elif [[ $5 == "Bundle_extract" ]]; then
		unzip "./download/$base_apk" -d "./download/$(basename "$base_apk" .apkm)" > /dev/null 2>&1
	fi
}
get_apkpure() {
	detect_version "$1"

	export version="$version"

	version=$(printf '%s\n' "$version" "$prefer_version" | sort -V | tail -n1)
	unset prefer_version

	if [[ $4 == "Bundle" ]] || [[ $4 == "Bundle_extract" ]]; then
		local base_apk="$2.xapk"
	else
		local base_apk="$2.apk"
	fi
	if [[ -n "$version" ]]; then
		url="https://apkpure.com/$3/downloading/$version"
	else
		url="https://apkpure.com/$3/downloading/"
		version="$(req "$url" - | awk -F'Download APK | \\(' '/<h2>/{print $2}')"
	fi
	green_log "[+] Downloading $2 version: $version $4"
	url="$(req "$url" - | grep -oP '<a[^>]+id="download_link"[^>]+href="\Khttps://[^"]+')"
	req "$url" "$base_apk"
	if [[ -f "./download/$base_apk" ]]; then
		green_log "[+] Successfully downloaded $2"
	else
		red_log "[-] Failed to download $2"
		exit 1
	fi
	if [[ $4 == "Bundle" ]]; then
		# Check if the downloaded file is an XAPK (contains .apk files) or already a standalone APK
		# XAPK files contain multiple .apk files, while APK files contain AndroidManifest.xml
		if unzip -l "./download/$base_apk" 2>/dev/null | grep -q '\.apk$'; then
			# It's an XAPK file with .apk files inside, needs merging
			green_log "[+] Merge splits apk to standalone apk"
			if ! java -jar $APKEditor m -i ./download/$2.xapk -o ./download/$2.apk > /dev/null 2>&1; then
				red_log "[-] Failed to merge $2.xapk to standalone apk"
				exit 1
			fi
		elif unzip -l "./download/$base_apk" 2>/dev/null | grep -q 'AndroidManifest.xml'; then
			# It's already a standalone APK file, just rename it
			green_log "[+] File is already a standalone APK, renaming"
			mv "./download/$base_apk" "./download/$2.apk"
		else
			red_log "[-] Unknown file format for $base_apk"
			exit 1
		fi
	elif [[ $4 == "Bundle_extract" ]]; then
		unzip "./download/$base_apk" -d "./download/$(basename "$base_apk" .xapk)" > /dev/null 2>&1
	fi
}

#################################################

# Patching apps with Revanced CLI:
patch() {
	green_log "[+] Patching $1:"
	if [ -f "./download/$1.apk" ]; then
		local p b m ks a pu opt force
		if [ "$3" = inotia ]; then
			p="patch " b="-p *.rvp" m="" a="" ks=" --keystore=./src/_ks.keystore" pu="--purge=true" opt="--legacy-options=./src/options/$2.json" force=" --force"
			echo "Patching with Revanced-cli inotia"
		elif [ "$3" = morphe ]; then
			p="patch " b="-p *.mpp" m="" a="" ks=" --keystore=./src/morphe.keystore --keystore-password=Morphe --keystore-entry-password=Morphe" pu="--purge=true" opt="--options-file ./src/options/$2.json" force=" --force"
			echo "Patching with Morphe"
		else
			if [[ $(ls revanced-cli-*.jar) =~ revanced-cli-([0-9]+) ]]; then
				num=${BASH_REMATCH[1]}
				if [ $num -eq 6 ]; then
					p="patch " b="-bp *.rvp" m="" a="" ks=" --keystore=./src/ks.keystore" pu="--purge=true" opt="" force=" --force"
					echo "Patching with Revanced-cli version 6+"
				elif [ $num -eq 5 ]; then
					p="patch " b="-p *.rvp" m="" a="" ks=" --keystore=./src/ks.keystore" pu="--purge=true" opt="" force=" --force"
					echo "Patching with Revanced-cli version 5"
				elif [ $num -eq 4 ]; then
					p="patch " b="--patch-bundle *patch*.jar" m="--merge *integration*.apk " a="" ks=" --keystore=./src/ks.keystore" pu="--purge=true" opt="--options=./src/options/$2.json "
					echo "Patching with Revanced-cli version 4"
				elif [ $num -eq 3 ]; then
					p="patch " b="--patch-bundle *patch*.jar" m="--merge *integration*.apk " a="" ks=" --keystore=./src/_ks.keystore" pu="--purge=true" opt="--options=./src/options/$2.json "
					echo "Patching with Revanced-cli version 3"
				elif [ $num -eq 2 ]; then
					p="" b="--bundle *patch*.jar" m="--merge *integration*.apk " a="--apk " ks=" --keystore=./src/_ks.keystore" pu="--clean" opt="--options=./src/options/$2.json " force=" --experimental"
					echo "Patching with Revanced-cli version 2"
				fi
			fi
		fi
		if [[ "$3" = inotia || "$3" = morphe ]]; then
			unset CI GITHUB_ACTION GITHUB_ACTIONS GITHUB_ACTOR GITHUB_ENV GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_HEAD_REF GITHUB_JOB GITHUB_REF GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_SHA GITHUB_WORKFLOW GITHUB_WORKSPACE RUN_ID RUN_NUMBER
		fi
		echo "java -jar *cli*.jar $p$b $m$opt --out=./release/$1-$2.apk$excludePatches$includePatches$ks $pu$force $a./download/$1.apk"
		eval java -jar *cli*.jar $p$b $m$opt --out=./release/$1-$2.apk$excludePatches$includePatches$ks $pu$force $a./download/$1.apk || {
			red_log "[-] Failed to patch $1"
			exit 1
		}
		postprocess_patched_apk "./release/$1-$2.apk" "$1"
  		unset version
		unset lock_version
		unset excludePatches
		unset includePatches
	else
		red_log "[-] Not found $1.apk"
		exit 1
	fi
}

#################################################

split_editor() {
    if [[ -z "$3" || -z "$4" ]]; then
        green_log "[+] Merge splits apk to standalone apk"
        java -jar $APKEditor m -i "./download/$1" -o "./download/$1.apk" > /dev/null 2>&1
        return 0
    fi
    IFS=' ' read -r -a include_files <<< "$4"
    mkdir -p "./download/$2"
    for file in "./download/$1"/*.apk; do
        filename=$(basename "$file")
        basename_no_ext="${filename%.apk}"
        if [[ "$filename" == "base.apk" ]]; then
            cp -f "$file" "./download/$2/" > /dev/null 2>&1
            continue
        fi
        if [[ "$3" == "include" ]]; then
            if [[ " ${include_files[*]} " =~ " ${basename_no_ext} " ]]; then
                cp -f "$file" "./download/$2/" > /dev/null 2>&1
            fi
        elif [[ "$3" == "exclude" ]]; then
            if [[ ! " ${include_files[*]} " =~ " ${basename_no_ext} " ]]; then
                cp -f "$file" "./download/$2/" > /dev/null 2>&1
            fi
        fi
    done

    green_log "[+] Merge splits apk to standalone apk"
    java -jar $APKEditor m -i ./download/$2 -o ./download/$2.apk > /dev/null 2>&1
}

#################################################

archs=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
libs=("armeabi-v7a x86_64 x86" "arm64-v8a x86_64 x86" "armeabi-v7a arm64-v8a x86" "armeabi-v7a arm64-v8a x86_64")

# Remove unused architectures directly
apk_editor() {
	local apk="$1" keep="$2"; shift 2
	local dir="./download/$apk"
	rm -rf "$dir" && unzip -q "./download/$apk.apk" -d "$dir" || return 1
	for r in "$@"; do rm -rf "$dir/lib/$r"; done
	(cd "$dir" && zip -qr "../$apk-$keep.apk" .)
}

# Split architectures using Morphe cli
split_arch() {
	green_log "[+] Splitting $1 to ${archs[i]}:"
	if [ -f "./download/$1.apk" ]; then
		eval java -jar *cli*.jar patch \
		-p *.mpp --options-file ./src/options/$2.json \
		--striplibs ${archs[i]} \
		--keystore=./src/morphe.keystore --keystore-password=Morphe --keystore-entry-password=Morphe --force \
		--out=./release/$1-${archs[i]}.apk\
		./download/$1.apk
	else
		red_log "[-] Not found $1.apk"
		exit 1
	fi
}
