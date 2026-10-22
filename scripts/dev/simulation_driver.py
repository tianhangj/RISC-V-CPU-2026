"""Derive a waveform-free driver from the course driver without changing it."""
from pathlib import Path


def without_trace(source):
    # Match the complete waveform setup, so a changed course driver cannot
    # silently lose unrelated behavior. Memory, AXI and cycle counting are kept.
    setup = '''        if (argc == 6) {
            top.trace(&trace, 99);
            trace.open(argv[5]);
            if (!trace.isOpen()) throw std::runtime_error("cannot open waveform");
        }'''
    replacements = [
        (setup, '''        if (argc == 6)
            throw std::runtime_error("waveform support disabled; rebuild with --trace (make TRACE=1)");''', 1),
        ('#include "verilated_vcd_c.h"\n', '', 1),
        ('        context.traceEverOn(argc == 6);\n', '', 1),
        ('        VerilatedVcdC trace;\n', '', 1),
        ('            if (argc == 6) trace.dump(context.time());\n', '', 2),
        ('        if (argc == 6) trace.close();\n', '', 1),
    ]
    for old, new, expected in replacements:
        if source.count(old) != expected:
            raise ValueError("course waveform driver changed; use --trace or update simulation_driver.py")
        source = source.replace(old, new)
    return source


def driver_source(course_driver, output, trace):
    if trace:
        return course_driver
    path = Path(output) / "sim_no_trace.cpp"
    source = without_trace(course_driver.read_text(encoding="utf-8"))
    # Preserve the mtime for Make's incremental dependency checks.
    if not path.is_file() or path.read_text(encoding="utf-8") != source:
        path.write_text(source, encoding="utf-8")
    return path
