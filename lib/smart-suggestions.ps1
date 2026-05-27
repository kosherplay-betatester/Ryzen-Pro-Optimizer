Set-StrictMode -Version Latest

function Get-SmartSuggestions {
    param(
        $Report,
        [string]$Mode,
        $CpuInfo,
        [int[]]$CurrentCoValues
    )
    $out = @()

    switch ($Report.verdict) {
        'PASSED' {
            switch ($Mode) {
                'all-cores' {
                    if ($CurrentCoValues -and $CurrentCoValues.Count -gt 0) {
                        $v = $CurrentCoValues[0]
                        $next = $v - 5
                        if ($CpuInfo -and $CpuInfo.IsDualCcd) {
                            $out += "All cores stable at $v. To push further, switch to Per-CCD mode: keep CCD0 at $v, try CCD1 at $next (CCD1 typically tolerates more)."
                        } else {
                            $next1 = $v - 2
                            $out += "All cores stable at $v. To push further, drop to $next1 (smaller steps near the edge), or try Per-core mode to push the strongest cores deeper."
                        }
                    }
                }
                'per-ccd' {
                    $out += "Per-CCD stable. To find each core's individual ceiling, switch to Per-core mode and tune the strongest cores deeper."
                }
                'per-core' {
                    $out += "Per-core stable - congrats! Now dial each core back by 2-3 points for a safe daily-use margin (thermals, summer heat, silicon aging)."
                }
            }
        }
        'FAILED' {
            if ($Report.coresFailed.Count -eq 1) {
                $c = $Report.coresFailed[0]
                $coAt = if ($null -ne $c.coAtFailure) { $c.coAtFailure } else { '?' }
                $back = if ($null -ne $c.coAtFailure) { $c.coAtFailure + 3 } else { '?' }
                $out += "Core $($c.core) hit its limit at CO=$coAt. Silicon lottery - that core happens to be less tolerant than your others. Dial back to $back and retry."
                if ($c.ccdLabel -match 'V-Cache') {
                    $out += "Core $($c.core) is on a V-Cache CCD. Those cores typically wall between -15 and -20. Step in 2-point increments from here."
                }
            } elseif ($Report.coresFailed.Count -gt 1) {
                $vCacheFails = @($Report.coresFailed | Where-Object { $_.ccdLabel -match 'V-Cache' })
                if ($vCacheFails.Count -ge 2) {
                    $out += "Multiple V-Cache cores errored. V-Cache CCDs usually wall between -15 and -20. Dial back CCD0 and step in 2-point increments from here."
                } else {
                    $failedList = ($Report.coresFailed | ForEach-Object { "core $($_.core)" }) -join ', '
                    $out += "Multiple cores errored: $failedList. Back off the offset across the board, then narrow per-core."
                }
            }
            if ($Report.wheaEvents -and $Report.wheaEvents.Count -gt 0) {
                $out += "WHEA events fired during the test - hardware-level corrected errors. Clear signal to back off the CO offset."
            }
        }
        'INCOMPLETE' {
            $out += "Test was stopped before completion. For confident results, run at least 3 full cycles."
        }
    }
    if ($Report.iterationsRequested -le 1 -and $Report.verdict -eq 'PASSED') {
        $out += "Tip: this was a 1-cycle test. Run 3+ cycles for higher confidence before committing the values to BIOS."
    }
    $out
}
