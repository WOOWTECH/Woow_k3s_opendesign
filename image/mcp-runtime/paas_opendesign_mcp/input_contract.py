"""Overlay HA 0.2.15's six input models onto the pinned 200e8c gateway table.

The pinned source and its SHA-256 manifest stay unchanged. Install after
ha_opendesign_mcp.runtime imports surface.install(), before state opens or
listeners start. Refuse an unexpected pin or table instead of widening it.
"""
from dataclasses import replace

from pydantic import Field, field_validator

from mcp_admin_core.products import FileInfo as PinnedFileInfo, Project as PinnedProject, TOOLS
from ha_opendesign_mcp import surface

from . import input_rules


class Project(PinnedProject):
    project_id: str = Field(max_length=128, pattern=input_rules.PROJECT_ID_PATTERN)


class FileInfo(PinnedFileInfo):
    project_id: str = Field(max_length=128, pattern=input_rules.PROJECT_ID_PATTERN)
    file_path: str = Field(min_length=1, max_length=256, pattern=input_rules.FILE_PATH_PATTERN)

    @field_validator('file_path')
    @classmethod
    def relative(cls, value):
        problem = input_rules.file_path_problem(value, for_read=False)
        if problem is not None:
            raise ValueError(problem)
        return value


class ReadFile(FileInfo):
    @field_validator('file_path')
    @classmethod
    def not_secret(cls, value):
        problem = input_rules.file_path_problem(value, for_read=True)
        if problem is not None:
            raise ValueError(problem)
        return value


class SendMessage(Project):
    prompt: str = surface.prompt_field()
    agent_id: str = surface.agent_field()


REPLACEMENTS = {
    'get_project': (PinnedProject, Project),
    'list_project_files': (PinnedProject, Project),
    'delete_project': (PinnedProject, Project),
    'get_file_info': (PinnedFileInfo, FileInfo),
    'read_file': (surface.ReadFile, ReadFile),
    'send_message': (surface.SendMessage, SendMessage),
}


def install():
    """Replace only six argument models; retain each Tool's grants and flags."""
    input_rules.require_pin()
    table = TOOLS['opendesign']
    if set(table) != surface.NAMES or len(table) != 15:
        raise RuntimeError('unexpected pinned OpenDesign tool table')
    for name, (old, new) in REPLACEMENTS.items():
        current = table[name].arguments
        if current not in (old, new):
            raise RuntimeError('unexpected pinned OpenDesign argument model: ' + name)
    if all(table[name].arguments is new for name, (_, new) in REPLACEMENTS.items()):
        return table
    if any(table[name].arguments is new for name, (_, new) in REPLACEMENTS.items()):
        raise RuntimeError('partial PaaS OpenDesign input overlay')
    if (surface.ADDED['read_file'].arguments is not surface.ReadFile
            or surface.ADDED['send_message'].arguments is not surface.SendMessage):
        raise RuntimeError('unexpected pinned OpenDesign added tools')
    for name, (_, new) in REPLACEMENTS.items():
        table[name] = replace(table[name], arguments=new)
    # Preserve surface.install() idempotence if the pinned module calls it again.
    for name in ('read_file', 'send_message'):
        surface.ADDED[name] = table[name]
    if surface.install() is not table:
        raise RuntimeError('OpenDesign tool table identity changed')
    return table
