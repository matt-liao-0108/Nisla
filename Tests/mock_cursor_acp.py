#!/usr/bin/env python3
"""Isolated ACP fixture: no account, model, shell or user files are accessed."""
import json, os, sys
assert sys.argv[1:] == ['acp']
active = None
session = None
session_count = 0

def emit(value):
    data = json.dumps(value, ensure_ascii=False) + '\n'
    # Exercise fragmented UTF-8 and NDJSON input handling.
    raw = data.encode()
    if len(raw) > 20:
        sys.stdout.buffer.write(raw[:17]); sys.stdout.buffer.flush()
        sys.stdout.buffer.write(raw[17:]); sys.stdout.buffer.flush()
    else:
        sys.stdout.buffer.write(raw); sys.stdout.buffer.flush()

def reply(identifier, result): emit({'jsonrpc':'2.0','id':identifier,'result':result})
def update(kind, text):
    emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':kind,'content':{'type':'text','text':text}}}})
def request(identifier, method, params): emit({'jsonrpc':'2.0','id':identifier,'method':method,'params':params})

for line in sys.stdin:
    row = json.loads(line)
    assert row['jsonrpc'] == '2.0'
    m, p, identifier = row.get('method'), row.get('params',{}), row.get('id')
    if m == 'initialize':
        assert p['protocolVersion'] == 1 and p['clientCapabilities']['terminal'] is False
        assert not p['clientCapabilities']['fs']['readTextFile']
        reply(identifier, {'protocolVersion': 2 if os.getcwd().endswith('bad-version') else 1, 'agentCapabilities':{'loadSession':not os.getcwd().endswith('no-load')},'authMethods':[{'id':'cursor_login'}]})
    elif m == 'authenticate':
        assert p == {'methodId':'cursor_login'}
        if os.getcwd().endswith('auth-fail'): emit({'jsonrpc':'2.0','id':identifier,'error':{'code':-32000,'message':'fixture-auth-required'}})
        else: reply(identifier,{})
    elif m == 'session/new':
        assert os.path.realpath(p['cwd']) == os.getcwd() and p['mcpServers'] == []
        session_count += 1; session = 'cursor-' + str(session_count)
        reply(identifier,{'sessionId':session})
    elif m == 'session/load':
        session = p['sessionId']
        update('user_message_chunk','Saved user')
        update('agent_thought_chunk','PRIVATE THOUGHT MUST NOT DISPLAY')
        update('agent_message_chunk','Saved assistant')
        reply(identifier,{})
    elif m == 'session/prompt':
        assert p['sessionId'] == session
        active = identifier
        text = p['prompt'][0]['text']
        if text == 'error':
            emit({'jsonrpc':'2.0','id':identifier,'error':{'code':-32000,'message':'fixture-prompt-denied'}}); active = None
        elif text == 'unknown': request('unsupported','fs/read_text_file',{'path':'/must-not-read'})
        elif text == 'long':
            update('agent_message_chunk','x'*100000); reply(identifier,{'stopReason':'end_turn'}); active=None
        else:
            update('user_message_chunk',text) # Echo must not duplicate user's optimistic message.
            update('agent_message_chunk','你好 ')
            update('agent_message_chunk','Cursor')
            request('permission','session/request_permission',{'sessionId':session,'toolCall':{'title':'Fixture tool','rawInput':{'fixture':True}},'options':[{'optionId':'permit','kind':'allow_once','name':'Once'},{'optionId':'deny','kind':'reject_once','name':'Reject'},{'optionId':'forever','kind':'allow_always','name':'Always'}]})
    elif m == 'session/cancel':
        assert identifier is None
        if active: reply(active,{'stopReason':'cancelled'}); active=None
    elif m is None and identifier == 'permission':
        if row['result']['outcome']['outcome'] == 'cancelled': continue
        assert row['result']['outcome'] == {'outcome':'selected','optionId':'deny'}
        request('question','cursor/ask_question',{'questions':[{'id':'q','prompt':'Which?','options':[{'id':'one','label':'One'}]}]})
    elif m is None and identifier == 'question':
        assert row['result'] == {'outcome':'answered','answers':[{'questionId':'q','selectedOptionIds':['one']}]}
        request('plan','cursor/create_plan',{'plan':'Fixture plan'})
    elif m is None and identifier == 'plan':
        assert row['result']['outcome']=='rejected'
        update('agent_message_chunk',' done')
        reply(active,{'stopReason':'end_turn'}); active=None
    elif m is None and identifier == 'unsupported':
        assert row['error']['code'] == -32601
        update('agent_message_chunk','Unsupported request rejected')
        reply(active,{'stopReason':'end_turn'}); active=None
    else: raise AssertionError(row)
