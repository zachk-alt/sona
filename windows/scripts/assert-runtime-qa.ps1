[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Report)
$ErrorActionPreference = 'Stop'
$qa = Get-Content -Raw -LiteralPath $Report | ConvertFrom-Json
if ($qa.status -ne 'passed' -or $qa.interactiveOutcome -ne 'passed') {
    throw 'Windows native QA requires a complete interactive pass. Partial or skipped checks are not a pass.'
}
$required = @('assistant_runtime_excluded','single_shortcut_api','registered_chord_activation','retired_command_chord_inert','retired_right_alt_tap_inert','retired_right_alt_hold_inert','left_alt_does_not_invoke','dictation_modifier_tap_still_works','dictation_second_tap_finishes','dictation_modifier_hold_finishes','dictation_other_key_discards_hold','dictation_chord_hold_finishes','dictation_chord_repeat_swallowed','compact_recording_size','shared_blue_active_icon','compact_processing_reshows_noactivate','learning_off_creates_no_worker','typed_dictation_none_passthrough','typed_rewrite_none_zero_text','model_sha256','english_default_selects_base_en','english_model_sha256','whisper_english_jfk_country','whisper_english_jfk_ask','whisper_switch_back_auto_country','speech_activity_fixture','parakeet_native_packaged','english_selects_parakeet','parakeet_model_sha256','parakeet_engine_used','parakeet_jfk_country','parakeet_jfk_ask','parakeet_jfk_americans','parakeet_kept_loaded','parakeet_fallback_whisper_country','parakeet_failed_folder_not_retried','parakeet_fallback_logged_code_no_text','parakeet_reload_after_fallback','whisper_backup_auto_route','credit_logo_resources','panel_uia_name_is_sona','panel_credit_is_help_text_not_name','panel_keeps_spot_processing','panel_keeps_spot_error','panel_fresh_show_places_again','tray_menu_about','tray_menu_mac_wording','tray_menu_dark_theme','tray_menu_light_theme','tray_left_click_menu_api','about_version_matches_release','about_credits','about_notices_packaged','reopen_signal_sent','reopen_signal_opens_settings_callback','reopen_without_listener_falls_back','clipboard_restored','pipeline_shared_conversion_exact_length','pipeline_speech_check_on_engine_audio','pipeline_warmed_parakeet_first_decode','pipeline_long_recording_in_pieces','pipeline_strict_mode_request_accepted')
# Spelling-suggestion observation is opt-in. Its checks are required whenever its helper starts.
if ($qa.checks.learning_anchor_supported -eq $true) {
    $required += @('learning_verified_inserted_range','learning_single_word_candidate','learning_focus_change_stops','learning_outside_typing_stops_before_read','learning_unwitnessed_change_zero_read','learning_hard_deadline_terminates_worker')
} else {
    Write-Host "Spelling-suggestion helper did not start on this runner: $($qa.checks.learning_start_failure)"
}
foreach ($name in $required) {
    if ($qa.checks.$name -ne $true) { throw "Required Windows feature check failed or missing: $name" }
}
# Parakeet timing on the runner, for the record (a shared CI machine, not user hardware).
Write-Host "Parakeet download $($qa.checks.parakeet_download_seconds) s, first run with load $($qa.checks.parakeet_first_run_seconds_with_load) s, warm run $($qa.checks.parakeet_warm_run_seconds) s"
Write-Host 'All required Windows interactive feature checks passed.'
