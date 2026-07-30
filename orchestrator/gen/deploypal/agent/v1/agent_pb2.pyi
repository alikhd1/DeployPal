from google.protobuf.internal import containers as _containers
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable, Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class Empty(_message.Message):
    __slots__ = ()
    def __init__(self) -> None: ...

class OpResult(_message.Message):
    __slots__ = ("ok", "message")
    OK_FIELD_NUMBER: _ClassVar[int]
    MESSAGE_FIELD_NUMBER: _ClassVar[int]
    ok: bool
    message: str
    def __init__(self, ok: _Optional[bool] = ..., message: _Optional[str] = ...) -> None: ...

class SystemInfo(_message.Message):
    __slots__ = ("hostname", "kernel", "distro", "mem_total", "cpu_count", "load1", "disk_total", "disk_free", "agent_version")
    HOSTNAME_FIELD_NUMBER: _ClassVar[int]
    KERNEL_FIELD_NUMBER: _ClassVar[int]
    DISTRO_FIELD_NUMBER: _ClassVar[int]
    MEM_TOTAL_FIELD_NUMBER: _ClassVar[int]
    CPU_COUNT_FIELD_NUMBER: _ClassVar[int]
    LOAD1_FIELD_NUMBER: _ClassVar[int]
    DISK_TOTAL_FIELD_NUMBER: _ClassVar[int]
    DISK_FREE_FIELD_NUMBER: _ClassVar[int]
    AGENT_VERSION_FIELD_NUMBER: _ClassVar[int]
    hostname: str
    kernel: str
    distro: str
    mem_total: int
    cpu_count: int
    load1: float
    disk_total: int
    disk_free: int
    agent_version: str
    def __init__(self, hostname: _Optional[str] = ..., kernel: _Optional[str] = ..., distro: _Optional[str] = ..., mem_total: _Optional[int] = ..., cpu_count: _Optional[int] = ..., load1: _Optional[float] = ..., disk_total: _Optional[int] = ..., disk_free: _Optional[int] = ..., agent_version: _Optional[str] = ...) -> None: ...

class ProcessInfo(_message.Message):
    __slots__ = ("pid", "ppid", "uid", "comm", "cmdline", "cwd", "exe", "unit", "rss", "cpu_pct")
    PID_FIELD_NUMBER: _ClassVar[int]
    PPID_FIELD_NUMBER: _ClassVar[int]
    UID_FIELD_NUMBER: _ClassVar[int]
    COMM_FIELD_NUMBER: _ClassVar[int]
    CMDLINE_FIELD_NUMBER: _ClassVar[int]
    CWD_FIELD_NUMBER: _ClassVar[int]
    EXE_FIELD_NUMBER: _ClassVar[int]
    UNIT_FIELD_NUMBER: _ClassVar[int]
    RSS_FIELD_NUMBER: _ClassVar[int]
    CPU_PCT_FIELD_NUMBER: _ClassVar[int]
    pid: int
    ppid: int
    uid: int
    comm: str
    cmdline: str
    cwd: str
    exe: str
    unit: str
    rss: int
    cpu_pct: float
    def __init__(self, pid: _Optional[int] = ..., ppid: _Optional[int] = ..., uid: _Optional[int] = ..., comm: _Optional[str] = ..., cmdline: _Optional[str] = ..., cwd: _Optional[str] = ..., exe: _Optional[str] = ..., unit: _Optional[str] = ..., rss: _Optional[int] = ..., cpu_pct: _Optional[float] = ...) -> None: ...

class ProcessList(_message.Message):
    __slots__ = ("processes",)
    PROCESSES_FIELD_NUMBER: _ClassVar[int]
    processes: _containers.RepeatedCompositeFieldContainer[ProcessInfo]
    def __init__(self, processes: _Optional[_Iterable[_Union[ProcessInfo, _Mapping]]] = ...) -> None: ...

class PortInfo(_message.Message):
    __slots__ = ("port", "proto", "address", "pid", "process", "unit")
    PORT_FIELD_NUMBER: _ClassVar[int]
    PROTO_FIELD_NUMBER: _ClassVar[int]
    ADDRESS_FIELD_NUMBER: _ClassVar[int]
    PID_FIELD_NUMBER: _ClassVar[int]
    PROCESS_FIELD_NUMBER: _ClassVar[int]
    UNIT_FIELD_NUMBER: _ClassVar[int]
    port: int
    proto: str
    address: str
    pid: int
    process: str
    unit: str
    def __init__(self, port: _Optional[int] = ..., proto: _Optional[str] = ..., address: _Optional[str] = ..., pid: _Optional[int] = ..., process: _Optional[str] = ..., unit: _Optional[str] = ...) -> None: ...

class PortList(_message.Message):
    __slots__ = ("ports",)
    PORTS_FIELD_NUMBER: _ClassVar[int]
    ports: _containers.RepeatedCompositeFieldContainer[PortInfo]
    def __init__(self, ports: _Optional[_Iterable[_Union[PortInfo, _Mapping]]] = ...) -> None: ...

class NginxSite(_message.Message):
    __slots__ = ("path", "enabled", "managed", "content", "mtime")
    PATH_FIELD_NUMBER: _ClassVar[int]
    ENABLED_FIELD_NUMBER: _ClassVar[int]
    MANAGED_FIELD_NUMBER: _ClassVar[int]
    CONTENT_FIELD_NUMBER: _ClassVar[int]
    MTIME_FIELD_NUMBER: _ClassVar[int]
    path: str
    enabled: bool
    managed: bool
    content: str
    mtime: int
    def __init__(self, path: _Optional[str] = ..., enabled: _Optional[bool] = ..., managed: _Optional[bool] = ..., content: _Optional[str] = ..., mtime: _Optional[int] = ...) -> None: ...

class NginxSiteList(_message.Message):
    __slots__ = ("sites",)
    SITES_FIELD_NUMBER: _ClassVar[int]
    sites: _containers.RepeatedCompositeFieldContainer[NginxSite]
    def __init__(self, sites: _Optional[_Iterable[_Union[NginxSite, _Mapping]]] = ...) -> None: ...

class ListUnitsRequest(_message.Message):
    __slots__ = ("pattern",)
    PATTERN_FIELD_NUMBER: _ClassVar[int]
    pattern: str
    def __init__(self, pattern: _Optional[str] = ...) -> None: ...

class UnitInfo(_message.Message):
    __slots__ = ("name", "description", "load_state", "active_state", "sub_state", "main_pid", "fragment_path", "enabled")
    NAME_FIELD_NUMBER: _ClassVar[int]
    DESCRIPTION_FIELD_NUMBER: _ClassVar[int]
    LOAD_STATE_FIELD_NUMBER: _ClassVar[int]
    ACTIVE_STATE_FIELD_NUMBER: _ClassVar[int]
    SUB_STATE_FIELD_NUMBER: _ClassVar[int]
    MAIN_PID_FIELD_NUMBER: _ClassVar[int]
    FRAGMENT_PATH_FIELD_NUMBER: _ClassVar[int]
    ENABLED_FIELD_NUMBER: _ClassVar[int]
    name: str
    description: str
    load_state: str
    active_state: str
    sub_state: str
    main_pid: int
    fragment_path: str
    enabled: bool
    def __init__(self, name: _Optional[str] = ..., description: _Optional[str] = ..., load_state: _Optional[str] = ..., active_state: _Optional[str] = ..., sub_state: _Optional[str] = ..., main_pid: _Optional[int] = ..., fragment_path: _Optional[str] = ..., enabled: _Optional[bool] = ...) -> None: ...

class UnitList(_message.Message):
    __slots__ = ("units",)
    UNITS_FIELD_NUMBER: _ClassVar[int]
    units: _containers.RepeatedCompositeFieldContainer[UnitInfo]
    def __init__(self, units: _Optional[_Iterable[_Union[UnitInfo, _Mapping]]] = ...) -> None: ...

class ReadFileRequest(_message.Message):
    __slots__ = ("path", "max_bytes")
    PATH_FIELD_NUMBER: _ClassVar[int]
    MAX_BYTES_FIELD_NUMBER: _ClassVar[int]
    path: str
    max_bytes: int
    def __init__(self, path: _Optional[str] = ..., max_bytes: _Optional[int] = ...) -> None: ...

class FileContent(_message.Message):
    __slots__ = ("content", "truncated")
    CONTENT_FIELD_NUMBER: _ClassVar[int]
    TRUNCATED_FIELD_NUMBER: _ClassVar[int]
    content: bytes
    truncated: bool
    def __init__(self, content: _Optional[bytes] = ..., truncated: _Optional[bool] = ...) -> None: ...

class ListDirRequest(_message.Message):
    __slots__ = ("path",)
    PATH_FIELD_NUMBER: _ClassVar[int]
    path: str
    def __init__(self, path: _Optional[str] = ...) -> None: ...

class DirEntry(_message.Message):
    __slots__ = ("name", "is_dir", "size")
    NAME_FIELD_NUMBER: _ClassVar[int]
    IS_DIR_FIELD_NUMBER: _ClassVar[int]
    SIZE_FIELD_NUMBER: _ClassVar[int]
    name: str
    is_dir: bool
    size: int
    def __init__(self, name: _Optional[str] = ..., is_dir: _Optional[bool] = ..., size: _Optional[int] = ...) -> None: ...

class DirListing(_message.Message):
    __slots__ = ("entries",)
    ENTRIES_FIELD_NUMBER: _ClassVar[int]
    entries: _containers.RepeatedCompositeFieldContainer[DirEntry]
    def __init__(self, entries: _Optional[_Iterable[_Union[DirEntry, _Mapping]]] = ...) -> None: ...

class FindFreePortRequest(_message.Message):
    __slots__ = ("range_start", "range_end", "exclude")
    RANGE_START_FIELD_NUMBER: _ClassVar[int]
    RANGE_END_FIELD_NUMBER: _ClassVar[int]
    EXCLUDE_FIELD_NUMBER: _ClassVar[int]
    range_start: int
    range_end: int
    exclude: _containers.RepeatedScalarFieldContainer[int]
    def __init__(self, range_start: _Optional[int] = ..., range_end: _Optional[int] = ..., exclude: _Optional[_Iterable[int]] = ...) -> None: ...

class FindFreePortResponse(_message.Message):
    __slots__ = ("port",)
    PORT_FIELD_NUMBER: _ClassVar[int]
    port: int
    def __init__(self, port: _Optional[int] = ...) -> None: ...

class UnitRef(_message.Message):
    __slots__ = ("name",)
    NAME_FIELD_NUMBER: _ClassVar[int]
    name: str
    def __init__(self, name: _Optional[str] = ...) -> None: ...

class InstallUnitRequest(_message.Message):
    __slots__ = ("name", "content", "enable", "start_now")
    NAME_FIELD_NUMBER: _ClassVar[int]
    CONTENT_FIELD_NUMBER: _ClassVar[int]
    ENABLE_FIELD_NUMBER: _ClassVar[int]
    START_NOW_FIELD_NUMBER: _ClassVar[int]
    name: str
    content: str
    enable: bool
    start_now: bool
    def __init__(self, name: _Optional[str] = ..., content: _Optional[str] = ..., enable: _Optional[bool] = ..., start_now: _Optional[bool] = ...) -> None: ...

class UnitActionRequest(_message.Message):
    __slots__ = ("name", "action")
    NAME_FIELD_NUMBER: _ClassVar[int]
    ACTION_FIELD_NUMBER: _ClassVar[int]
    name: str
    action: str
    def __init__(self, name: _Optional[str] = ..., action: _Optional[str] = ...) -> None: ...

class NginxSiteRef(_message.Message):
    __slots__ = ("filename",)
    FILENAME_FIELD_NUMBER: _ClassVar[int]
    filename: str
    def __init__(self, filename: _Optional[str] = ...) -> None: ...

class WriteNginxSiteRequest(_message.Message):
    __slots__ = ("filename", "content")
    FILENAME_FIELD_NUMBER: _ClassVar[int]
    CONTENT_FIELD_NUMBER: _ClassVar[int]
    filename: str
    content: str
    def __init__(self, filename: _Optional[str] = ..., content: _Optional[str] = ...) -> None: ...

class CertRequest(_message.Message):
    __slots__ = ("domains", "contact_email")
    DOMAINS_FIELD_NUMBER: _ClassVar[int]
    CONTACT_EMAIL_FIELD_NUMBER: _ClassVar[int]
    domains: _containers.RepeatedScalarFieldContainer[str]
    contact_email: str
    def __init__(self, domains: _Optional[_Iterable[str]] = ..., contact_email: _Optional[str] = ...) -> None: ...

class RecipeParam(_message.Message):
    __slots__ = ("name", "type", "default", "values", "min", "max", "required", "advanced", "derived_hint", "unit_suffix")
    NAME_FIELD_NUMBER: _ClassVar[int]
    TYPE_FIELD_NUMBER: _ClassVar[int]
    DEFAULT_FIELD_NUMBER: _ClassVar[int]
    VALUES_FIELD_NUMBER: _ClassVar[int]
    MIN_FIELD_NUMBER: _ClassVar[int]
    MAX_FIELD_NUMBER: _ClassVar[int]
    REQUIRED_FIELD_NUMBER: _ClassVar[int]
    ADVANCED_FIELD_NUMBER: _ClassVar[int]
    DERIVED_HINT_FIELD_NUMBER: _ClassVar[int]
    UNIT_SUFFIX_FIELD_NUMBER: _ClassVar[int]
    name: str
    type: str
    default: str
    values: _containers.RepeatedScalarFieldContainer[str]
    min: int
    max: int
    required: bool
    advanced: bool
    derived_hint: str
    unit_suffix: str
    def __init__(self, name: _Optional[str] = ..., type: _Optional[str] = ..., default: _Optional[str] = ..., values: _Optional[_Iterable[str]] = ..., min: _Optional[int] = ..., max: _Optional[int] = ..., required: _Optional[bool] = ..., advanced: _Optional[bool] = ..., derived_hint: _Optional[str] = ..., unit_suffix: _Optional[str] = ...) -> None: ...

class Recipe(_message.Message):
    __slots__ = ("id", "kind", "name", "description", "unit", "default_port", "packages", "params", "source", "installed", "installed_version", "config_path")
    ID_FIELD_NUMBER: _ClassVar[int]
    KIND_FIELD_NUMBER: _ClassVar[int]
    NAME_FIELD_NUMBER: _ClassVar[int]
    DESCRIPTION_FIELD_NUMBER: _ClassVar[int]
    UNIT_FIELD_NUMBER: _ClassVar[int]
    DEFAULT_PORT_FIELD_NUMBER: _ClassVar[int]
    PACKAGES_FIELD_NUMBER: _ClassVar[int]
    PARAMS_FIELD_NUMBER: _ClassVar[int]
    SOURCE_FIELD_NUMBER: _ClassVar[int]
    INSTALLED_FIELD_NUMBER: _ClassVar[int]
    INSTALLED_VERSION_FIELD_NUMBER: _ClassVar[int]
    CONFIG_PATH_FIELD_NUMBER: _ClassVar[int]
    id: str
    kind: str
    name: str
    description: str
    unit: str
    default_port: int
    packages: _containers.RepeatedScalarFieldContainer[str]
    params: _containers.RepeatedCompositeFieldContainer[RecipeParam]
    source: str
    installed: bool
    installed_version: str
    config_path: str
    def __init__(self, id: _Optional[str] = ..., kind: _Optional[str] = ..., name: _Optional[str] = ..., description: _Optional[str] = ..., unit: _Optional[str] = ..., default_port: _Optional[int] = ..., packages: _Optional[_Iterable[str]] = ..., params: _Optional[_Iterable[_Union[RecipeParam, _Mapping]]] = ..., source: _Optional[str] = ..., installed: _Optional[bool] = ..., installed_version: _Optional[str] = ..., config_path: _Optional[str] = ...) -> None: ...

class RecipeList(_message.Message):
    __slots__ = ("recipes", "catalog_version")
    RECIPES_FIELD_NUMBER: _ClassVar[int]
    CATALOG_VERSION_FIELD_NUMBER: _ClassVar[int]
    recipes: _containers.RepeatedCompositeFieldContainer[Recipe]
    catalog_version: str
    def __init__(self, recipes: _Optional[_Iterable[_Union[Recipe, _Mapping]]] = ..., catalog_version: _Optional[str] = ...) -> None: ...

class InstallServiceRequest(_message.Message):
    __slots__ = ("recipe_id", "params")
    class ParamsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    RECIPE_ID_FIELD_NUMBER: _ClassVar[int]
    PARAMS_FIELD_NUMBER: _ClassVar[int]
    recipe_id: str
    params: _containers.ScalarMap[str, str]
    def __init__(self, recipe_id: _Optional[str] = ..., params: _Optional[_Mapping[str, str]] = ...) -> None: ...

class RemoveServiceRequest(_message.Message):
    __slots__ = ("recipe_id", "purge")
    RECIPE_ID_FIELD_NUMBER: _ClassVar[int]
    PURGE_FIELD_NUMBER: _ClassVar[int]
    recipe_id: str
    purge: bool
    def __init__(self, recipe_id: _Optional[str] = ..., purge: _Optional[bool] = ...) -> None: ...

class InstallProgress(_message.Message):
    __slots__ = ("step", "status", "log", "done", "ok", "facts", "secrets")
    class FactsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    class SecretsEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    STEP_FIELD_NUMBER: _ClassVar[int]
    STATUS_FIELD_NUMBER: _ClassVar[int]
    LOG_FIELD_NUMBER: _ClassVar[int]
    DONE_FIELD_NUMBER: _ClassVar[int]
    OK_FIELD_NUMBER: _ClassVar[int]
    FACTS_FIELD_NUMBER: _ClassVar[int]
    SECRETS_FIELD_NUMBER: _ClassVar[int]
    step: str
    status: str
    log: str
    done: bool
    ok: bool
    facts: _containers.ScalarMap[str, str]
    secrets: _containers.ScalarMap[str, str]
    def __init__(self, step: _Optional[str] = ..., status: _Optional[str] = ..., log: _Optional[str] = ..., done: _Optional[bool] = ..., ok: _Optional[bool] = ..., facts: _Optional[_Mapping[str, str]] = ..., secrets: _Optional[_Mapping[str, str]] = ...) -> None: ...

class LogStreamRequest(_message.Message):
    __slots__ = ("unit", "tail_lines", "follow", "cursor")
    UNIT_FIELD_NUMBER: _ClassVar[int]
    TAIL_LINES_FIELD_NUMBER: _ClassVar[int]
    FOLLOW_FIELD_NUMBER: _ClassVar[int]
    CURSOR_FIELD_NUMBER: _ClassVar[int]
    unit: str
    tail_lines: int
    follow: bool
    cursor: str
    def __init__(self, unit: _Optional[str] = ..., tail_lines: _Optional[int] = ..., follow: _Optional[bool] = ..., cursor: _Optional[str] = ...) -> None: ...

class LogLine(_message.Message):
    __slots__ = ("ts_micros", "priority", "message", "cursor")
    TS_MICROS_FIELD_NUMBER: _ClassVar[int]
    PRIORITY_FIELD_NUMBER: _ClassVar[int]
    MESSAGE_FIELD_NUMBER: _ClassVar[int]
    CURSOR_FIELD_NUMBER: _ClassVar[int]
    ts_micros: int
    priority: int
    message: str
    cursor: str
    def __init__(self, ts_micros: _Optional[int] = ..., priority: _Optional[int] = ..., message: _Optional[str] = ..., cursor: _Optional[str] = ...) -> None: ...

class ResourceStreamRequest(_message.Message):
    __slots__ = ("units", "interval_seconds")
    UNITS_FIELD_NUMBER: _ClassVar[int]
    INTERVAL_SECONDS_FIELD_NUMBER: _ClassVar[int]
    units: _containers.RepeatedScalarFieldContainer[str]
    interval_seconds: int
    def __init__(self, units: _Optional[_Iterable[str]] = ..., interval_seconds: _Optional[int] = ...) -> None: ...

class ResourceSample(_message.Message):
    __slots__ = ("unit", "ts", "cpu_pct", "mem_bytes", "disk_bytes")
    UNIT_FIELD_NUMBER: _ClassVar[int]
    TS_FIELD_NUMBER: _ClassVar[int]
    CPU_PCT_FIELD_NUMBER: _ClassVar[int]
    MEM_BYTES_FIELD_NUMBER: _ClassVar[int]
    DISK_BYTES_FIELD_NUMBER: _ClassVar[int]
    unit: str
    ts: int
    cpu_pct: float
    mem_bytes: int
    disk_bytes: int
    def __init__(self, unit: _Optional[str] = ..., ts: _Optional[int] = ..., cpu_pct: _Optional[float] = ..., mem_bytes: _Optional[int] = ..., disk_bytes: _Optional[int] = ...) -> None: ...

class WatchPathsRequest(_message.Message):
    __slots__ = ("paths",)
    PATHS_FIELD_NUMBER: _ClassVar[int]
    paths: _containers.RepeatedScalarFieldContainer[str]
    def __init__(self, paths: _Optional[_Iterable[str]] = ...) -> None: ...

class FsEvent(_message.Message):
    __slots__ = ("path", "op", "ts")
    PATH_FIELD_NUMBER: _ClassVar[int]
    OP_FIELD_NUMBER: _ClassVar[int]
    TS_FIELD_NUMBER: _ClassVar[int]
    path: str
    op: str
    ts: int
    def __init__(self, path: _Optional[str] = ..., op: _Optional[str] = ..., ts: _Optional[int] = ...) -> None: ...
