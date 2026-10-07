[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Report)
$ErrorActionPreference = 'Stop'
$qa = Get-Content -Raw -LiteralPath $Report | ConvertFrom-Json
if ($qa.status -ne 'passed' -or $qa.interactiveOutcome -ne 'passed') {
    throw 'Windows native QA requires a complete interactive pass. Partial or skipped checks are not a pass.'
}
$required = @('assistant_runtime_excluded','single_shortcut_api','registered_chord_activation','retired_command_chord_inert','retired_right_alt_tap_inert','retired_right_alt_hold_inert','left_alt_does_not_invoke','dictation_modifier_tap_still_works','compact_recording_size','shared_blue_active_icon','compact_processing_reshows_noactivate','learning_off_creates_no_worker','typed_dictation_none_passthrough','typed_rewrite_none_zero_text')
# Spelling-suggestion observation is opt-in. Its checks are required whenever its helper starts.
if ($qa.checks.learning_anchor_supported -eq $true) {
    $required += @('learning_verified_inserted_range','learning_single_word_candidate','learning_focus_change_stops','learning_outside_typing_stops_before_read','learning_unwitnessed_change_zero_read','learning_hard_deadline_terminates_worker')
} else {
    Write-Host "Spelling-suggestion helper did not start on this runner: $($qa.checks.learning_start_failure)"
}
foreach ($name in $required) {
    if ($qa.checks.$name -ne $true) { throw "Required Windows feature check failed or missing: $name" }
}
Write-Host 'All required Windows interactive feature checks passed.'
