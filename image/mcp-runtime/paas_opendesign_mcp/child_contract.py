"""Apply HA 0.2.15's safe project/file input guards to the pinned child.

The gateway advertises and validates the six overlaid schemas. This child
guard also covers callers of the private child socket and prevents a wider
gateway schema from promising arguments the old child would reject.
"""
import functools
import inspect
import re

from . import input_rules

GUARDED = ('get_project', 'delete_project', 'list_project_files', 'get_file_info')


def prepare(ha_child):
    """Patch only the pinned child entry's install hook, before it starts."""
    input_rules.require_pin()
    from backend_policy import backend_errors
    from ha_opendesign_mcp import od_rules, od_tools

    if (od_rules.FILE_PATH.pattern != r'[A-Za-z0-9_. /-]{1,256}'
            or od_tools.REPLACED != ('list_connectors', 'read_file', 'create_project', 'send_message')
            or ha_child.od_tools is not od_tools):
        raise RuntimeError('unexpected pinned OpenDesign child input rules')
    original_install = od_tools.install
    od_rules.FILE_PATH = re.compile(input_rules.FILE_PATH_PATTERN)

    def require_project_id(value):
        if not input_rules.safe_project_id(value):
            raise od_tools.Refused('INVALID_ARGUMENTS')
        return value

    od_tools._project_id = require_project_id

    def install(mcp, od):
        handlers = original_install(mcp, od)
        tools = mcp._tool_manager._tools
        if len(tools) != 15:
            raise RuntimeError('unexpected pinned OpenDesign child tool count')
        for name in GUARDED:
            tool = tools.get(name)
            if tool is None or tool.is_async:
                raise RuntimeError('unexpected pinned OpenDesign child tool: ' + name)
            original = tool.fn
            signature = inspect.signature(original)
            expected = ('project_id', 'file_path') if name == 'get_file_info' else ('project_id',)
            if tuple(signature.parameters) != expected:
                raise RuntimeError('unexpected pinned OpenDesign child signature: ' + name)

            @backend_errors
            @functools.wraps(original)
            def guarded(*args, __fn=original, __name=name, __signature=signature, **kwargs):
                arguments = __signature.bind(*args, **kwargs).arguments
                require_project_id(arguments['project_id'])
                if (__name == 'get_file_info'
                        and input_rules.file_path_problem(arguments['file_path'], for_read=False) is not None):
                    raise od_tools.Refused('INVALID_ARGUMENTS')
                return __fn(*args, **kwargs)

            tool.fn = guarded
        for name in (*GUARDED, 'read_file', 'send_message'):
            tool = tools[name]
            if tool.description.count('UUID of the project') != 1:
                raise RuntimeError('unexpected pinned OpenDesign child description: ' + name)
            tool.description = tool.description.replace('UUID of the project',
                                                        'Safe project ID (UUID or imported ID)')
        return handlers

    od_tools.install = install
