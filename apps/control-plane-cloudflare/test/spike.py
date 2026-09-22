"""Exercise real Worker/D1/Workflow over HTTP; never print credentials."""
import json, os, pathlib, time, urllib.request, urllib.error, uuid
root = pathlib.Path(__file__).resolve().parents[1]
env = dict(line.split('=', 1) for line in (root / '.dev.vars').read_text().splitlines() if '=' in line)
base = os.environ.get('RUNDIFF_TEST_URL', 'http://127.0.0.1:5173')
def call(path, body=None, token=None, expected=200):
    request = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, headers={'content-type': 'application/json', 'user-agent': 'RunDiff-VS1-Verification/1.0', **({'authorization': 'Bearer ' + token} if token else {})})
    try:
        response = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    payload = response.read().decode()
    assert response.code == expected, (path, response.code, payload)
    return json.loads(payload)
def wait(review_id, status):
    for _ in range(100):
        review = call('/api/reviews/' + review_id)['review']
        if review['status'] == status:
            return review
        time.sleep(.2)
    raise AssertionError(review)
call('/api/health'); call('/api/ready')
call('/api/spike/reviews', {}, expected=401)
records = []
decisions = os.environ.get('RUNDIFF_TEST_DECISIONS', 'BLOCK,ALLOW,REVIEW,INFRA_FAILURE').split(',')
for decision in decisions:
    identity = {'repository':'demo/shop', 'pull_request_number':int(time.time_ns() % 1000000000), 'scenario_id':'orders.show', 'baseline_sha':'a'*40, 'candidate_sha':uuid.uuid4().hex + 'b'*8}
    created = call('/api/spike/reviews', identity, env['RUNDIFF_SPIKE_TOKEN'], 201)
    review_id = created['review']['id']
    wait(review_id, 'waiting_for_executor')
    claimed = call('/api/execution-bridges/github-actions/claim', identity, env['RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN'])['request']
    assert claimed == created['execution']
    assert set(claimed) == {'schema_version','execution_id','scenario_id','baseline_sha','candidate_sha','attempt_number','context'}
    path = '/api/executions/' + claimed['execution_id'] + '/attempts/1/result'
    result = {'schema_version':'1', 'status':'failed' if decision == 'INFRA_FAILURE' else 'succeeded', 'payload':{'result':{'merge_recommendation':decision.lower()}}, 'error_class':'ExecutorFailure' if decision == 'INFRA_FAILURE' else None, 'error_message':None}
    call(path.replace('/1/', '/1junk/'), result, env['RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN'], 422)
    call(path.replace('/1/', '/2/'), result, env['RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN'], 409)
    call(path, result, env['RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN'], 202)
    review = wait(review_id, 'infra_failure' if decision == 'INFRA_FAILURE' else 'completed')
    assert review['decision'] == decision, review
    assert call(path, result, env['RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN'], 202)['status'] == 'duplicate'
    conflict = {**result, 'error_message':'different result'}
    call(path, conflict, env['RUNDIFF_GITHUB_ACTIONS_BRIDGE_TOKEN'], 409)
    assert call('/api/reviews/' + review_id)['review'] == review
    records.append({'review_id':review_id,'execution_id':claimed['execution_id'],'decision':decision})
    print('PASS', decision, review_id, flush=True)
pathlib.Path('/private/tmp/rundiff-spike-results.json').write_text(json.dumps(records, indent=2))
if os.environ.get('RUNDIFF_TEST_TIMEOUT') == '1':
    identity['pull_request_number'] += 1
    created = call('/api/spike/reviews', identity, env['RUNDIFF_SPIKE_TOKEN'], 201)
    review = wait(created['review']['id'], 'infra_failure')
    assert review['decision'] == 'INFRA_FAILURE'
    print('PASS timeout INFRA_FAILURE', review['id'], flush=True)
