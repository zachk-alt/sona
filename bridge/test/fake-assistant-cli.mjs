import { createInterface } from 'node:readline';
import { appendFileSync, readFileSync } from 'node:fs';
const args = process.argv.slice(2), scenario = process.env.SONA_FAKE_CASE ?? 'answer';
const record = (data) => { if (process.env.SONA_FAKE_RECORD) appendFileSync(process.env.SONA_FAKE_RECORD, JSON.stringify(data) + '\n'); };
const emit = (data) => process.stdout.write(JSON.stringify(data) + '\n');
const model = args[args.indexOf('--model') + 1];
const answer = scenario === 'detailed_answer'
  ? Array.from({ length: 80 }, (_, index) => `Detail${index + 1}`).join(' ') + '\n\n```swift\nlet complete = true\n```'
  : 'A synthetic blue square.';
const answerResponse = { kind: 'answer', text: answer };
// Retired response shapes are negative fixtures only. Neither transport may return them successfully.
const actionResponse = { kind: 'actions', text: 'Press Return.', actions: [{ type: 'key', key: 'enter' }] };
const blenderResponse = { kind: 'blender', text: 'Cube.', scene: { version: 1, objects: [{ type: 'cube' }] } };
const screenResponse = {
  open_chrome_guidance: { kind: 'answer', text: 'Open Google Chrome from your Applications folder or search for it in your app launcher.' },
  navigation_guidance: { kind: 'answer', text: 'Choose Create, then Video in the visible navigation menu.' },
  followup_guidance: { kind: 'answer', text: 'Choose Video in the open Create menu.' },
  actions: actionResponse,
  blender: blenderResponse,
  wait_action: { kind: 'actions', text: 'Wait.', actions: [{ type: 'wait', milliseconds: 750 }] },
  answer_actions: { ...answerResponse, actions: [] },
  answer_scene: { ...answerResponse, scene: blenderResponse.scene },
  answer_artifacts: { ...answerResponse, artifacts: { blendPath: '/synthetic/scene.blend', previewPath: '/synthetic/preview.png' } },
}[scenario] ?? answerResponse;
const fenced = (body, label = 'json') => '```' + label + '\n' + JSON.stringify(body) + '\n```';
const screenOutput = {
  fenced_answer: fenced(answerResponse),
  fenced_click: fenced(actionResponse, ''),
  fenced_blender: fenced(blenderResponse),
  fenced_answer_actions: fenced({ ...answerResponse, actions: [] }),
  fenced_answer_scene: fenced({ ...answerResponse, scene: blenderResponse.scene }),
  fenced_answer_artifacts: fenced({ ...answerResponse, artifacts: {} }),
  fenced_extra_response_field: fenced({ ...answerResponse, explanation: 'Extra field.' }),
  fenced_array_response: fenced([answerResponse]),
}[scenario] ?? JSON.stringify(screenResponse);
if (args[0] === 'exec') {
  let raw = ''; for await (const value of process.stdin) raw += value;
  const payload = JSON.parse(raw), images = [];
  for (let index = 0; index < args.length; index++) if (args[index] === '--image') images.push(readFileSync(args[index + 1]).toString('base64'));
  record({ generation: true, args, payload, images });
  if (scenario === 'fail') process.exit(1);
  const text = payload.selection ? 'Rewritten selection.' : screenOutput;
  emit({ type: 'thread.started', thread_id: 'synthetic' });
  emit({ type: 'item.completed', item: { type: 'agent_message', text } });
  emit({ type: 'turn.completed', usage: { input_tokens: 1, output_tokens: 1 } });
} else {
  for await (const line of createInterface({ input: process.stdin })) {
    const request = JSON.parse(line);
    if (request.method === 'initialize') emit({ id: request.id, result: {} });
    else if (request.method === 'model/list') {
      record({ catalog: true, provider: 'codex' });
      emit({ id: request.id, result: { data: [
        ...(scenario === 'astra_catalog' ? [{ model: 'gpt-6-astra', displayName: 'GPT-6-Astra', isDefault: true, inputModalities: ['text', 'image'],
          supportedReasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].map((reasoningEffort) => ({ reasoningEffort })), defaultReasoningEffort: 'medium' }] : []),
        { model: 'gpt-5.6-luna', displayName: 'Luna', inputModalities: ['text', 'image'], supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'high' }], defaultReasoningEffort: 'high' },
        { model: 'gpt-5.3-codex-spark', displayName: 'Spark', inputModalities: ['text'], supportedReasoningEfforts: [{ reasoningEffort: 'high' }], defaultReasoningEffort: 'high' },
      ], nextCursor: null } });
    } else if (request.type === 'control_request') {
      record({ catalog: true, provider: 'claude' });
      if (scenario === 'catalog_structured_error') emit({ type: 'error', error: { type: 'authentication_error', message: 'PRIVATE_PROVIDER_DIAGNOSTIC' } });
      emit({ type: 'control_response', response: { subtype: 'success', request_id: request.request_id, response: { account: { ignored: 'synthetic' }, models: [
        { value: 'default', resolvedModel: 'claude-opus-5', displayName: 'Default', supportsEffort: true, supportedEffortLevels: ['low', 'high', 'max'] },
        { value: 'haiku', resolvedModel: 'claude-haiku-4-5-20251001', displayName: 'Haiku' },
      ] } } });
    } else if (request.type === 'user') {
      const payload = JSON.parse(request.message.content[0].text);
      record({ generation: true, args, payload, images: request.message.content.filter((item) => item.type === 'image').map((item) => item.source.data) });
      if (scenario === 'hang') await new Promise(() => setInterval(() => {}, 10000));
      if (scenario === 'fail') process.exit(1);
      emit({ type: 'system', subtype: 'init', model, tools: scenario === 'tools' ? ['Bash'] : [], mcp_servers: [] });
      const privateDiagnostic = 'PRIVATE_PROVIDER_DIAGNOSTIC must never be forwarded';
      if (scenario.startsWith('sdk_error:')) emit({ type: 'assistant', error: scenario.slice('sdk_error:'.length),
        message: { model, content: [{ type: 'text', text: privateDiagnostic }] } });
      if (scenario.startsWith('api_error:')) emit({ type: 'error', error: { type: scenario.slice('api_error:'.length), message: privateDiagnostic } });
      if (scenario === 'structured_error_tool_priority') emit({ type: 'assistant', error: 'authentication_failed',
        message: { model, content: [{ type: 'tool_use', name: 'Bash', input: { privateDiagnostic } }] } });
      if (scenario === 'structured_error_server_tool_priority') emit({ type: 'assistant', error: { type: 'billing_error', message: privateDiagnostic },
        message: { model, content: [{ type: 'server_tool_use', name: 'web_search', input: { privateDiagnostic } }] } });
      if (scenario === 'structured_error_init_priority') emit({ type: 'system', subtype: 'init', error: 'authentication_failed', tools: ['Bash'], mcp_servers: [] });
      if (scenario === 'structured_error_message_only') emit({ type: 'error', error: { message: 'authentication_failed ' + privateDiagnostic } });
      if (scenario === 'structured_error_unknown') emit({ type: 'assistant', error: privateDiagnostic, message: { model, content: [] } });
      if (scenario === 'structured_error_max_tokens') emit({ type: 'assistant', message: { model, stop_reason: 'max_tokens', content: [{ type: 'text', text: privateDiagnostic }] } });
      if (scenario === 'malformed_assistant_content_object') emit({ type: 'assistant', message: { model, content: { type: 'tool_use' } } });
      if (scenario === 'malformed_assistant_content_string') emit({ type: 'assistant', message: { model, content: privateDiagnostic } });
      emit({ type: 'assistant', message: { model, content: [{ type: 'text', text: 'complete' }] } });
      let result = payload.selection ? 'Rewritten selection.' : screenOutput;
      if (scenario === 'malformed') result = 'Not JSON';
      if (scenario === 'stream_error') emit({ type: 'error', message: 'synthetic failure' });
      const frame = { type: 'result', subtype: scenario === 'error' ? 'error_during_execution' : 'success', is_error: scenario === 'error', num_turns: 1, result };
      if (scenario === 'result_error_field') frame.error = { message: 'synthetic failure' };
      if (scenario === 'result_errors') frame.errors = ['synthetic failure'];
      if (scenario === 'result_errors_shape') frame.errors = {};
      if (scenario === 'result_missing_flag') delete frame.is_error;
      if (scenario === 'result_missing_turns') delete frame.num_turns;
      if (scenario === 'result_denials_shape') frame.permission_denials = {};
      emit(frame);
      if (scenario === 'result_hang') await new Promise(() => setInterval(() => {}, 10000));
      if (scenario === 'result_fail') process.exit(1);
    }
  }
}
