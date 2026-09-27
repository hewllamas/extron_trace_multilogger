# extron_trace_multilogger
Live multi-processor trace logging for Extron ControlScript (Python) systems. A Python TraceServer runs inside the program and streams per-room debug trace over telnet (TCP 6000). A PowerShell multilogger connects to many processors at once and writes each to its own timestamped log file.
