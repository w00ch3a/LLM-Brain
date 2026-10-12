"""Memory-Gym-style task family for the real memory-on/off evaluation.

JAM's Memory-Gym taxonomy (single-hop, multi-hop, multi-session
summarisation) applied to one synthetic field-lab project, plus tasks that
exercise the 0.9 features: folder summaries (#6), progressive state (#7),
cascading invalidation (#8), sufficiency-gated recall (#9) and label lineage.
Answers go to ``answer.json`` and are graded deterministically by the
research grader; no model grades anything.  All content is synthetic.
"""

SOURCES = {
    "sources/HL-S01.md": "# HL-S01: Halden river station log, sessions 1-3\n\nSource ID: HL-S01\n\nThe station runs automatic samplers at three sites (Upper, Weir, Delta).\n",
    "sources/HL-S02.md": "# HL-S02: Instrument inventory sheet\n\nSource ID: HL-S02\n\nInventory lists sensors by tag only; site assignment is kept in the field notebook.\n",
    "sources/HL-S03.md": "# HL-S03: Dredge notice\n\nSource ID: HL-S03\n\nThe Weir site channel was dredged in May 2025.\n",
    "README.md": "# Halden river nitrate study\n\nCollected source excerpts are in sources/. Each file carries its source ID.\n",
}
ALLOWED = ["HL-S01", "HL-S02", "HL-S03", "HL-S04", "HL-S05", "HL-S06", "HL-S07", "HL-S08"]

# Session-dated memory.  Several facts only make sense together (multi-hop);
# the sampling decision changed twice (multi-session); the interval changed
# without an explicit supersedes link (implicit invalidation, #8).
MEMORY = [
    {"id": "hl-sensor-site", "title": "Sensor N-7 placement", "text": "Nitrate sensor N-7 is installed at the Delta site (notebook HL-S04).", "observed_at": "2026-01-05T00:00:00Z"},
    {"id": "hl-delta-factor", "title": "Delta calibration factor", "text": "All Delta site nitrate readings are multiplied by calibration factor 1.07 (calibration sheet HL-S05).", "observed_at": "2026-01-06T00:00:00Z"},
    {"id": "hl-protocol-v1", "title": "Sampling protocol decision (session 1)", "text": "Session 1 decision: grab samples weekly at all three sites (HL-S04).", "observed_at": "2026-01-05T00:00:00Z",
     "state_key": "halden.sampling.protocol", "labels": [["decision-point:sampling", "initial protocol"]]},
    {"id": "hl-protocol-v2", "title": "Sampling protocol decision (session 2)", "text": "Session 2 decision: switch to automatic samplers at all sites because weekly grabs missed storm pulses (HL-S06).", "observed_at": "2026-02-10T00:00:00Z",
     "state_key": "halden.sampling.protocol", "supersedes": "hl-protocol-v1", "labels": [["decision-point:sampling", "storm pulses missed"]]},
    {"id": "hl-protocol-v3", "title": "Sampling protocol decision (session 3)", "text": "Session 3 decision: keep automatic samplers but drop the Weir site after the May 2025 dredge disturbed the bed (HL-S07).", "observed_at": "2026-03-15T00:00:00Z",
     "state_key": "halden.sampling.protocol", "supersedes": "hl-protocol-v2", "labels": [["decision-point:sampling", "Weir dropped"]]},
    {"id": "hl-interval-12", "title": "Autosampler interval", "text": "Autosamplers draw a sample every 12 hours.", "observed_at": "2026-02-10T00:00:00Z", "state_key": "halden.sampler.interval"},
    {"id": "hl-daily-count", "title": "Samples per site per day", "text": "Each site yields 2 samples per day from the autosampler interval.", "observed_at": "2026-02-11T00:00:00Z", "derived_from": ["hl-interval-12"]},
    {"id": "hl-interval-6", "title": "Autosampler interval update", "text": "From session 3 the autosamplers draw a sample every 6 hours to resolve diurnal swings (HL-S08).", "observed_at": "2026-03-15T00:00:00Z", "state_key": "halden.sampler.interval"},
    {"id": "hl-pump-rate", "title": "Pump rate", "text": "Autosampler pump rate is 350 mL per minute.", "observed_at": "2026-02-10T00:00:00Z", "state_key": "halden.pump.rate"},
    {"id": "hl-instr-1", "title": "Instrument: N-7 nitrate sensor", "text": "Instrument record: N-7 optical nitrate sensor.", "observed_at": "2026-01-05T00:00:00Z"},
    {"id": "hl-instr-2", "title": "Instrument: T-2 thermistor", "text": "Instrument record: T-2 water thermistor.", "observed_at": "2026-01-05T00:00:00Z"},
    {"id": "hl-instr-3", "title": "Instrument: C-4 conductivity probe", "text": "Instrument record: C-4 conductivity probe.", "observed_at": "2026-01-05T00:00:00Z"},
    {"id": "hl-instr-4", "title": "Instrument: P-1 pressure logger", "text": "Instrument record: P-1 pressure logger.", "observed_at": "2026-01-05T00:00:00Z"},
]
# Seeding runs `llm-brain invalidate apply` from the later interval so the
# implicit replacement and its derived count carry outcome labels, and builds
# folder summaries (`browse build`).
INVALIDATE = ["hl-interval-6"]

MEMORY_ONLY = ["HL-S04", "HL-S05", "HL-S06", "HL-S07", "HL-S08", "1.07", "6 hours", "Weir site after"]


def halden(task):
    task.update(project_id="proj_halden", files=dict(SOURCES), memory=list(MEMORY), intentions=[], allowed_citations=ALLOWED,
                invalidate=list(INVALIDATE), build_summaries=True, family="memorygym", memory_only=MEMORY_ONLY if task["kind"] != "control" else [])
    return task


TASKS = [
    halden({
        "id": "m01-single-hop-site", "kind": "memory", "knowledge": "single-hop",
        "question": "At which Halden site is nitrate sensor N-7 installed?",
        "schema": {"site": "Upper, Weir or Delta", "citations": ["source IDs"]},
        "checks": [{"field": "site", "regex": "^\\s*Delta\\s*$"}, {"citations_include": ["HL-S04"]}],
        "reference": {"queries": ["sensor N-7 site"], "needs": ["Delta"],
                      "answer_on": {"site": "Delta", "citations": ["HL-S04"]}, "answer_off": {"site": "Upper", "citations": ["HL-S02"]}},
    }),
    halden({
        "id": "m02-multi-hop-factor", "kind": "memory", "knowledge": "multi-hop",
        "question": "What calibration factor must be applied to readings from sensor N-7, and why?",
        "schema": {"factor": "number", "answer": "1-2 sentences", "citations": ["source IDs"]},
        "checks": [{"field": "factor", "equals": 1.07}, {"citations_include": ["HL-S04", "HL-S05"]}],
        "reference": {"queries": ["sensor N-7 site", "Delta calibration factor"], "needs": ["Delta site (notebook", "1.07"],
                      "answer_on": {"factor": 1.07, "answer": "N-7 is at Delta (HL-S04) and Delta readings use 1.07 (HL-S05).", "citations": ["HL-S04", "HL-S05"]},
                      "answer_off": {"factor": 1.0, "answer": "No factor is documented.", "citations": ["HL-S02"]}},
    }),
    halden({
        "id": "m03-multi-session-summary", "kind": "memory", "knowledge": "multi-session-summary+lineage",
        "question": "Summarise how the Halden sampling protocol decision changed across the project sessions, in order, and state the current protocol.",
        "schema": {"changes": ["one string per session, in order"], "current_protocol": "1 sentence", "citations": ["source IDs"]},
        "checks": [
            {"field": "changes", "regex": "weekly.*automatic.*Weir"},
            {"field": "current_protocol", "regex": "automatic"}, {"field": "current_protocol", "regex": "Weir"},
            {"field": "current_protocol", "not_regex": "weekly grab"},
            {"citations_include": ["HL-S06", "HL-S07"]},
        ],
        "reference": {"commands": [["lineage", "show", "proj_halden", "--decision", "sampling"]], "needs": ["decision (session 1)", "decision (session 3)", "supersedes"],
                      "answer_on": {"changes": ["Session 1: weekly grab samples (HL-S04)", "Session 2: automatic samplers after missed storm pulses (HL-S06)", "Session 3: automatic samplers, Weir site dropped after the dredge (HL-S07)"],
                                    "current_protocol": "Automatic samplers at Upper and Delta; Weir dropped.", "citations": ["HL-S04", "HL-S06", "HL-S07"]},
                      "answer_off": {"changes": ["Automatic samplers at three sites (HL-S01)"], "current_protocol": "Automatic samplers at Upper, Weir and Delta.", "citations": ["HL-S01"]}},
    }),
    halden({
        "id": "m04-implicit-invalidation", "kind": "memory", "knowledge": "cascading-invalidation",
        "question": "How many samples per site per day does the Halden autosampler currently produce?",
        "schema": {"samples_per_day": "number", "answer": "1-2 sentences", "citations": ["source IDs"]},
        "checks": [{"field": "samples_per_day", "equals": 4}, {"citations_include": ["HL-S08"]}],
        "reference": {"queries": ["autosampler interval"], "commands": [["state", "index", "proj_halden"]], "needs": ["every 6 hours"],
                      "answer_on": {"samples_per_day": 4, "answer": "Every 6 hours since session 3 (HL-S08), so 4 per day; the older 2-per-day figure is stale.", "citations": ["HL-S08"]},
                      "answer_off": {"samples_per_day": 2, "answer": "Twice daily.", "citations": ["HL-S01"]}},
    }),
    halden({
        "id": "m05-label-lineage-where", "kind": "memory", "knowledge": "label-lineage",
        "question": "At which session did the Halden sampling decision last change, what changed, and what triggered it?",
        "schema": {"session": "number", "change": "1 sentence", "trigger": "1 sentence", "citations": ["source IDs"]},
        "checks": [{"field": "session", "equals": 3}, {"field": "change", "regex": "Weir"}, {"field": "trigger", "regex": "dredg"}, {"citations_include": ["HL-S07"]}],
        "reference": {"commands": [["lineage", "show", "proj_halden", "--decision", "sampling"]], "needs": ["Session 3 decision", "Weir dropped"],
                      "answer_on": {"session": 3, "change": "The Weir site was dropped.", "trigger": "The May 2025 dredge disturbed the bed (HL-S03, HL-S07).", "citations": ["HL-S07", "HL-S03"]},
                      "answer_off": {"session": 1, "change": "Samplers installed.", "trigger": "Study start.", "citations": ["HL-S01"]}},
    }),
    halden({
        "id": "m06-folder-browse", "kind": "memory", "knowledge": "folder-summary",
        "question": "List every instrument recorded in the Halden project memory by tag.",
        "schema": {"instruments": ["tags"], "count": "number"},
        "checks": [{"field": "count", "equals": 4}, {"field": "instruments", "regex": "N-7"}, {"field": "instruments", "regex": "P-1"}],
        "reference": {"commands": [["browse", "show", "proj_halden", "okf/claims"]], "needs": ["Instrument: P-1", "Instrument: C-4"],
                      "answer_on": {"instruments": ["N-7", "T-2", "C-4", "P-1"], "count": 4}, "answer_off": {"instruments": [], "count": 0}},
    }),
    halden({
        "id": "m07-current-state", "kind": "memory", "knowledge": "progressive-state",
        "question": "Give the current autosampler interval (hours) and pump rate (mL per minute) for Halden.",
        "schema": {"interval_hours": "number", "pump_ml_per_min": "number", "citations": ["source IDs"]},
        "checks": [{"field": "interval_hours", "equals": 6}, {"field": "pump_ml_per_min", "equals": 350}],
        "reference": {"commands": [["state", "index", "proj_halden"]], "needs": ["every 6 hours", "350 mL"],
                      "answer_on": {"interval_hours": 6, "pump_ml_per_min": 350, "citations": ["HL-S08"]}, "answer_off": {"interval_hours": 12, "pump_ml_per_min": 0, "citations": ["HL-S01"]}},
    }),
    halden({
        "id": "m08-sufficiency-two-facts", "kind": "memory", "knowledge": "sufficiency",
        "question": "Which Halden sensor needs a calibration factor, at which site is it, and what is the pump rate there?",
        "schema": {"sensor": "tag", "site": "site", "factor": "number", "pump_ml_per_min": "number"},
        "checks": [{"field": "sensor", "regex": "N-7"}, {"field": "site", "regex": "Delta"}, {"field": "factor", "equals": 1.07}, {"field": "pump_ml_per_min", "equals": 350}],
        "reference": {"commands": [["recall-check", "proj_halden", "sensor calibration factor Delta pump rate"]], "queries": ["sensor N-7 site", "Delta calibration factor", "pump rate"], "needs": ["1.07", "350 mL", "Delta site"],
                      "answer_on": {"sensor": "N-7", "site": "Delta", "factor": 1.07, "pump_ml_per_min": 350}, "answer_off": {"sensor": "unknown", "site": "unknown", "factor": 1.0, "pump_ml_per_min": 0}},
    }),
    halden({
        "id": "m09-control-dredge", "kind": "control", "knowledge": "none",
        "question": "When was the Weir site channel dredged?",
        "schema": {"when": "month and year", "citations": ["source IDs"]},
        "checks": [{"field": "when", "regex": "May.*2025|2025-05"}, {"citations_include": ["HL-S03"]}],
        "reference": {"queries": ["dredge"], "needs": [],
                      "answer_on": {"when": "May 2025", "citations": ["HL-S03"]}, "answer_off": {"when": "May 2025", "citations": ["HL-S03"]}},
    }),
]
