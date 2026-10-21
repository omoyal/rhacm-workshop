#!/usr/bin/env python3
"""Workshop preparation and evidence checks. Draft: no target execution claimed.
No credentials are read/exported. Every oc call specifies a context.
"""
import argparse, copy, json, os, re, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
STATE=ROOT/'.workshop'; OWNER='rhacm-workshop-day2'; KEY='workshop.rhacm.io/owner'
LABELS={KEY:OWNER}; SET='ws-candidates'; PRODSET='ws-production'; GKNS='ws-gatekeeper'; CAPNS='ws-governance'; DEMONS='ws-demos'
CFG={}
def fail(message): raise RuntimeError(message)
def run(args,input=None,check=True):
 p=subprocess.run(args,input=input,text=True,capture_output=True)
 if check and p.returncode: fail('Command failed: '+' '.join(args)+'\n'+p.stderr)
 return p

def oc(ctx,*args,input=None,check=True):
 return run(['oc','--context',ctx,'--request-timeout=30s',*args],input,check)
def get(ctx,kind,name=None,namespace=None):
 args=['get',kind]+([name] if name else [])+(['-n',namespace] if namespace else [])+['-o','json']
 p=oc(ctx,*args,check=False)
 if p.returncode:
  if 'NotFound' in p.stderr or 'not found' in p.stderr:return None
  fail(p.stderr)
 return json.loads(p.stdout)
def obj(kind,name,spec=None,ns=None,api='v1',**extra):
 o={'apiVersion':api,'kind':kind,'metadata':{'name':name,'labels':dict(LABELS)}}
 if ns:o['metadata']['namespace']=ns
 if spec is not None:o['spec']=spec
 o.update(extra);return o

def save(name,objects):
 STATE.mkdir(exist_ok=True)
 f=STATE/(name+'.json');f.write_text(json.dumps({'apiVersion':'v1','kind':'List','items':objects},indent=2)+'\n')
 return f

def apply(ctx,objects,name):
 for o in objects:
  old=get(ctx,o['kind'],o['metadata']['name'],o['metadata'].get('namespace'))
  if old and old.get('metadata',{}).get('labels',{}).get(KEY)!=OWNER:
   fail('Refusing to overwrite unowned resource: '+o['kind']+'/'+o['metadata']['name'])
 f=save(name,objects)
 print(oc(ctx,'apply','-f',str(f)).stdout,end='')

def wait_for(description,fn,seconds=180):
 stop=time.monotonic()+seconds
 while time.monotonic()<stop:
  if fn():print('PASS:',description);return
  time.sleep(3)
 fail('Timed out: '+description+'. Inspect status and Events before continuing.')

def cfg():
 global CFG
 f=ROOT/'workshop-config.json'
 if not f.exists():fail('Copy workshop-config.example.json to workshop-config.json and set all context names and the image digest.')
 CFG=json.loads(f.read_text())
 if any('REPLACE_' in str(v) for v in CFG.values()):fail('Replace every REPLACE_ value in workshop-config.json.')
 if not re.fullmatch(r'[^\s]+@sha256:[0-9a-f]{64}',CFG['image_pinned']):fail('image_pinned must use an explicit sha256 digest.')
 if not CFG['image_latest'].endswith(':latest'):fail('image_latest must end with :latest for this exercise.')
 if len({CFG[k] for k in ['hub_context','stage_context','prod_context']})!=3:fail('Use three distinct context names for this workshop.')
 if CFG['stage_cluster']==CFG['prod_cluster']:fail('Stage and production must be distinct managed clusters.')
 return CFG

def preflight():
 c=CFG
 for role in ['hub','stage','prod']:
  ctx=c[role+'_context'];who=oc(ctx,'whoami').stdout.strip()
  print(role,ctx,'identity:',who)
  if oc(ctx,'auth','can-i','*','*').stdout.strip()!='yes':fail('This isolated lab requires cluster-admin access on '+role)
  cv=get(ctx,'clusterversion','version');print('OpenShift:',cv['status'].get('desired',{}).get('version'))
 for role in ['stage','prod']:
  m=get(c['hub_context'],'managedcluster',c[role+'_cluster'])
  if not m:fail('ManagedCluster missing for '+role)
  if not any(x['type']=='ManagedClusterConditionAvailable' and x['status']=='True' for x in m['status'].get('conditions',[])):fail(role+' ManagedCluster is unavailable')
  server=oc(c[role+'_context'],'config','view','--minify','-o','jsonpath={.clusters[0].cluster.server}').stdout.rstrip('/')
  urls=[x['url'].rstrip('/') for x in m['spec'].get('managedClusterClientConfigs',[])]
  if server not in urls:fail(role+' context API does not match the ManagedCluster API URL. Resolve the context mapping first.')
  for addon in ['governance-policy-framework','config-policy-controller']:
   a=get(c['hub_context'],'managedclusteraddon',addon,c[role+'_cluster'])
   if not a or not any(x['type']=='Available' and x['status']=='True' for x in a.get('status',{}).get('conditions',[])):fail('Add-on not ready: '+role+'/'+addon)
 print('PASS: context identity, cluster availability and governance add-ons. Image pulls and exercises are NOT tested by this check.')

def label_cluster(name,key,value):
 ctx=CFG['hub_context'];m=get(ctx,'managedcluster',name);STATE.mkdir(exist_ok=True)
 f=STATE/'original-labels.json';original=json.loads(f.read_text()) if f.exists() else {}
 original.setdefault(name,{})
 if key not in original[name]:original[name][key]=m['metadata'].get('labels',{}).get(key)
 f.write_text(json.dumps(original,indent=2))
 print(oc(ctx,'label','managedcluster',name,key+'='+value,'--overwrite').stdout,end='')
 if key=='workshop.rhacm.io/finale':label_cluster(name,'workshop.rhacm.io/cluster',name)

def sets(ns):
 return [obj('Namespace',ns),obj('ManagedClusterSet',SET,{'clusterSelector':{'selectorType':'LabelSelector','labelSelector':{'matchLabels':{'workshop.rhacm.io/finale':'true'}}}},api='cluster.open-cluster-management.io/v1beta2'),obj('ManagedClusterSetBinding',SET,{'clusterSet':SET},ns,api='cluster.open-cluster-management.io/v1beta2')]

def placement(ns,name,clusterset=SET,prod=False):
 spec={'clusterSets':[clusterset]}
 if prod:spec['predicates']=[{'requiredClusterSelector':{'labelSelector':{'matchLabels':{'workshop.rhacm.io/cluster':CFG['prod_cluster']}}}}]
 return obj('Placement',name,spec,ns,api='cluster.open-cluster-management.io/v1beta1')
def binding(ns,name,place,policies):
 return obj('PlacementBinding',name,ns=ns,api='policy.open-cluster-management.io/v1',placementRef={'apiGroup':'cluster.open-cluster-management.io','kind':'Placement','name':place},subjects=[{'apiGroup':'policy.open-cluster-management.io','kind':'Policy','name':p} for p in policies])
def policy(ns,name,templates,action='inform'):
 return obj('Policy',name,{'disabled':False,'remediationAction':action,'policy-templates':[{'objectDefinition':t} for t in templates]},ns,api='policy.open-cluster-management.io/v1')
def cp(name,objects,action='inform',compliance='musthave'):
 return obj('ConfigurationPolicy',name,{'remediationAction':action,'severity':'medium','pruneObjectBehavior':'None','object-templates':[{'complianceType':compliance,'objectDefinition':o} for o in objects]},api='policy.open-cluster-management.io/v1')
def decisions(ns,name):
 d=json.loads(oc(CFG['hub_context'],'get','placementdecisions','-n',ns,'-l','cluster.open-cluster-management.io/placement='+name,'-o','json').stdout)
 return sorted({x['clusterName'] for i in d['items'] for x in i.get('status',{}).get('decisions',[])})
def check_targets(ns,name,expected):
 actual=decisions(ns,name)
 if actual!=sorted(expected):fail('Unexpected Placement targets: '+str(actual)+'; expected '+str(expected))
 print('PASS: exact targets',actual)

def engine_ready():
 for role in ['stage','prod']:
  ctx=CFG[role+'_context'];g=get(ctx,'gatekeepers.operator.gatekeeper.sh','gatekeeper')
  if not g:fail('Gatekeeper CR missing on '+role)
  pods=get(ctx,'pods',namespace=CFG['gatekeeper_namespace'])['items']
  for token in ['audit','controller-manager']:
   matching=[p for p in pods if token in p['metadata']['name'] and not p['metadata'].get('deletionTimestamp')]
   if not matching or not all(any(x['type']=='Ready' and x['status']=='True' for x in p['status'].get('conditions',[])) for p in matching):fail(role+': Gatekeeper '+token+' pods not Ready; inspect actual workload names if changed.')
 print('PASS: Gatekeeper CR and audit/webhook pods on both targets')

def prepare_gk():
 preflight();engine_ready()
 apply(CFG['hub_context'],sets(GKNS),'gatekeeper-scope')
 for role in ['stage','prod']:label_cluster(CFG[role+'_cluster'],'workshop.rhacm.io/finale','true')
 for role,names in [('stage',['ws-stage','ws-stage-exempt']),('prod',['ws-prod'])]:
  apply(CFG[role+'_context'],[obj('Namespace',n) for n in names],role+'-namespaces')
 for role in ['stage','prod']:
  for kind,name in [('constrainttemplate','wscontainertags'),('WsContainerTags','ws-no-latest')]:
   # WsContainerTags may not yet exist as a resource type.
   if kind=='constrainttemplate' and get(CFG[role+'_context'],kind,name):fail('Remove the previous wscontainertags exercise before starting again.')
 make_gk_files()
 print('LAB READY. Files generated in .workshop/. Apply the rules yourself using the lab guide.')

def make_gk_files():
 rego="""package wscontainertags
import rego.v1
containers := input.review.object.spec.containers if { input.review.kind.kind == "Pod" }
containers := input.review.object.spec.template.spec.containers if { input.review.kind.kind == "Deployment" }
violation contains {"msg": msg} if {
  some c in containers
  endswith(c.image, ":latest")
  msg := sprintf("Container %v uses forbidden image tag latest: %v", [c.name, c.image])
}
"""
 ct=obj('ConstraintTemplate','wscontainertags',{'crd':{'spec':{'names':{'kind':'WsContainerTags'},'validation':{'openAPIV3Schema':{'type':'object'}}}},'targets':[{'target':'admission.k8s.gatekeeper.sh','rego':rego}]},api='templates.gatekeeper.sh/v1')
 con=obj('WsContainerTags','ws-no-latest',{'enforcementAction':'deny','match':{'kinds':[{'apiGroups':[''],'kinds':['Pod']},{'apiGroups':['apps'],'kinds':['Deployment']}],'namespaces':['ws-stage','ws-stage-exempt','ws-prod']}},api='constraints.gatekeeper.sh/v1beta1')
 pol=policy(GKNS,'ws-image-tags',[ct,con],'enforce')
 save('gatekeeper-rules',[pol,placement(GKNS,'ws-gk-targets'),binding(GKNS,'ws-gk-binding','ws-gk-targets',['ws-image-tags','ws-admission-report'])])
 ev={'apiVersion':'v1','kind':'Event','metadata':{'namespace':CFG['gatekeeper_namespace'],'annotations':{'constraint_action':'deny','constraint_kind':'WsContainerTags','constraint_name':'ws-no-latest','event_type':'violation'}}}
 save('gatekeeper-report',[policy(GKNS,'ws-admission-report',[cp('ws-admission-events',[ev],'inform','mustnothave')],'inform')])
 for name,ns,latest in [('stage-bad','ws-stage',True),('stage-exempt','ws-stage-exempt',True),('prod-bad','ws-prod',True),('prod-good','ws-prod',False)]:save(name,[deployment('hello',ns,CFG['image_latest'] if latest else CFG['image_pinned'])])
 save('gatekeeper-exclusion-patch',[ ]) # overwrite as merge patch, not an API List
 (STATE/'gatekeeper-exclusion-patch.json').write_text(json.dumps({'spec':{'config':{'disableDefaultMatches':False,'matches':[{'excludedNamespaces':['ws-stage-exempt'],'processes':['*']}]},'webhook':{'emitAdmissionEvents':'Enabled'}}},indent=2))

def deployment(name,ns,image=None,replicas=1,uid=None):
 sc={'allowPrivilegeEscalation':False,'capabilities':{'drop':['ALL']},'runAsNonRoot':True,'seccompProfile':{'type':'RuntimeDefault'}}
 if uid:sc['runAsUser']=uid
 container={'name':'server','image':image or CFG['image_pinned'],'command':['python3','-m','http.server','8080','--directory','/tmp'],'ports':[{'containerPort':8080}],'resources':{'requests':{'cpu':'50m','memory':'64Mi'},'limits':{'cpu':'100m','memory':'128Mi'}},'securityContext':sc}
 return obj('Deployment',name,{'replicas':replicas,'selector':{'matchLabels':{'app':name}},'template':{'metadata':{'labels':{'app':name,**LABELS}},'spec':{'containers':[container]}}},ns,api='apps/v1')

def check_gk():
 engine_ready();check_targets(GKNS,'ws-gk-targets',[CFG['stage_cluster'],CFG['prod_cluster']])
 for role in ['stage','prod']:
  con=get(CFG[role+'_context'],'WsContainerTags','ws-no-latest')
  if not con or con['spec'].get('enforcementAction')!='deny':fail('Constraint not in deny on '+role)
  ct=get(CFG[role+'_context'],'constrainttemplate','wscontainertags')
  if not ct or any(x.get('errors') for x in ct.get('status',{}).get('byPod',[])):fail('Template missing or has errors on '+role)
 print('PASS: distribution and effective action. Run the allow/deny requests and inspect Events as described in the guide.')

def prepare_capstone():
 preflight();hub=CFG['hub_context'];prod=CFG['prod_context']
 apply(hub,sets(CAPNS),'capstone-scope')
 for role in ['stage','prod']:label_cluster(CFG[role+'_cluster'],'workshop.rhacm.io/finale','true')
 for role in ['stage','prod']:
  m=get(hub,'managedcluster',CFG[role+'_cluster'])
  if 'workshop.rhacm.io/environment' in m['metadata'].get('labels',{}):fail('Remove prior workshop environment label before this scenario.')
 production=obj('ManagedClusterSet',PRODSET,{'clusterSelector':{'selectorType':'LabelSelector','labelSelector':{'matchLabels':{'workshop.rhacm.io/environment':'production'}}}},api='cluster.open-cluster-management.io/v1beta2')
 bindset=obj('ManagedClusterSetBinding',PRODSET,{'clusterSet':PRODSET},CAPNS,api='cluster.open-cluster-management.io/v1beta2')
 audit=policy(CAPNS,'ws-production-baseline',[cp('ws-namespace-baseline',[obj('Namespace','ws-app')])])
 apply(hub,[production,bindset,audit,placement(CAPNS,'ws-production-targets'),binding(CAPNS,'ws-production-binding','ws-production-targets',['ws-production-baseline'])],'capstone-incident')
 # Audit only while Placement is deliberately wrong. Workloads are created on production only.
 apply(prod,[obj('Namespace','ws-app')],'app-namespace')
 server=deployment('api','ws-app')
 clients=[]
 for name,access in [('client','wrong'),('outsider','blocked')]:
  d=deployment(name,'ws-app');d['spec']['template']['metadata']['labels']['access']=access
  d['spec']['template']['spec']['containers'][0]['command']=['python3','-c','import time; time.sleep(86400)'];clients.append(d)
 svc=obj('Service','api',{'selector':{'app':'api'},'ports':[{'port':8080,'targetPort':8080}]},'ws-app')
 apply(prod,[server,*clients,svc],'app-workloads')
 deny=obj('NetworkPolicy','ws-default-deny',{'podSelector':{},'policyTypes':['Ingress']},'ws-app',api='networking.k8s.io/v1')
 allow=obj('NetworkPolicy','ws-allow-client',{'podSelector':{'matchLabels':{'app':'api'}},'policyTypes':['Ingress'],'ingress':[{'from':[{'podSelector':{'matchLabels':{'access':'allowed'}}}],'ports':[{'protocol':'TCP','port':8080}]}]},'ws-app',api='networking.k8s.io/v1')
 quota=obj('ResourceQuota','ws-budget',{'hard':{'requests.cpu':'200m','requests.memory':'256Mi','limits.cpu':'400m','limits.memory':'512Mi','pods':'4'}},'ws-app')
 limit=obj('LimitRange','ws-defaults',{'limits':[{'type':'Container','default':{'cpu':'100m','memory':'128Mi'},'defaultRequest':{'cpu':'50m','memory':'64Mi'},'max':{'cpu':'200m','memory':'256Mi'}}]},'ws-app')
 base=policy(CAPNS,'ws-app-controls',[cp('ws-network-and-budget',[deny,allow,quota,limit],'enforce')],'enforce')
 apply(hub,[base,placement(CAPNS,'ws-app-targets',prod=True),binding(CAPNS,'ws-app-binding','ws-app-targets',['ws-app-controls'])],'app-controls')
 for kind,name in [('networkpolicy','ws-default-deny'),('networkpolicy','ws-allow-client'),('resourcequota','ws-budget'),('limitrange','ws-defaults')]:
  wait_for('Application control exists: '+name,lambda kind=kind,name=name: bool(get(prod,kind,name,'ws-app')))
 for n in ['api','client','outsider']:print(oc(prod,'rollout','status','deployment/'+n,'-n','ws-app','--timeout=180s').stdout)
 print('LAB READY. A read-only policy has wrong targets. Networking is deliberately blocked. Do not change all faults at once.')

def netcheck(client,expect):
 ctx=CFG['prod_context']
 script="import urllib.request; print(urllib.request.urlopen('http://api.ws-app.svc:8080', timeout=4).status)"
 p=oc(ctx,'exec','-n','ws-app','deployment/'+client,'--','python3','-c',script,check=False)
 if p.returncode==0:
  if expect!='allow':fail(client+' unexpectedly reached api')
  print('PASS:',client,'HTTP',p.stdout.strip())
 else:
  if expect=='allow':fail(p.stderr)
  if not any(s in p.stderr for s in ['timed out','TimeoutError']):fail('Failure is not a confirmed network timeout: '+p.stderr)
  print('PASS:',client,'timed out as expected')

def check_capstone():
 check_targets(CAPNS,'ws-production-targets',[CFG['prod_cluster']])
 members=oc(CFG['hub_context'],'get','managedclusters','-l','workshop.rhacm.io/environment=production','-o','json').stdout
 if sorted(x['metadata']['name'] for x in json.loads(members)['items'])!=[CFG['prod_cluster']]:fail('Production set must contain exactly the production cluster')
 netcheck('client','allow');netcheck('outsider','deny')
 d=get(CFG['prod_context'],'deployment','api','ws-app')
 if d.get('status',{}).get('availableReplicas',0)!=3:fail('Expected 3 available api replicas')
 q=get(CFG['prod_context'],'resourcequota','ws-budget','ws-app');print('Quota hard:',q['spec']['hard'],'used:',q.get('status',{}).get('used',{}))
 print('PASS: final scenario checks. Also inspect policy Results and record the root cause at each checkpoint.')

def prepare_scc():
 preflight();ctx=CFG['prod_context'];hub=CFG['hub_context'];ns='ws-scc'
 apply(hub,sets(DEMONS),'demo-scope')
 label_cluster(CFG['prod_cluster'],'workshop.rhacm.io/finale','true')
 apply(ctx,[obj('Namespace',ns),obj('ServiceAccount','ws-app',ns=ns)],'scc-start')
 # Copy restrictive defaults rather than weakening built-in SCCs. Custom UID is non-root.
 source=get(ctx,'securitycontextconstraints','restricted-v2')
 if not source:fail('restricted-v2 is required for this demo')
 source['metadata']={'name':'ws-fixed-uid','labels':dict(LABELS)};source.pop('status',None)
 source['users']=[];source['groups']=[];source['runAsUser']={'type':'MustRunAs','uid':1001}
 d=deployment('fixed-uid',ns,uid=1001);d['spec']['template']['spec']['serviceAccountName']='ws-app'
 # On the inspected OCP version this also makes selection deterministic.
 d['spec']['template']['metadata']['annotations']={'openshift.io/required-scc':'ws-fixed-uid'}
 role=obj('Role','ws-use-fixed-uid',ns=ns,api='rbac.authorization.k8s.io/v1',rules=[{'apiGroups':['security.openshift.io'],'resources':['securitycontextconstraints'],'resourceNames':['ws-fixed-uid'],'verbs':['use']}])
 rb=obj('RoleBinding','ws-use-fixed-uid',ns=ns,api='rbac.authorization.k8s.io/v1',subjects=[{'kind':'ServiceAccount','name':'ws-app','namespace':ns}],roleRef={'apiGroup':'rbac.authorization.k8s.io','kind':'Role','name':'ws-use-fixed-uid'})
 apply(hub,[policy(DEMONS,'ws-scc-definition',[cp('ws-custom-scc',[source],'enforce')],'enforce'),placement(DEMONS,'ws-demo-targets',prod=True),binding(DEMONS,'ws-demo-binding','ws-demo-targets',['ws-scc-definition','ws-scc-access'])],'scc-policy')
 save('scc-access',[policy(DEMONS,'ws-scc-access',[cp('ws-scc-rbac',[role,rb],'enforce')],'enforce')])
 wait_for('Custom SCC exists',lambda: bool(get(ctx,'securitycontextconstraints','ws-fixed-uid')))
 apply(ctx,[d],'scc-deployment')
 print('DEMO READY. Inspect ReplicaSet Events before applying .workshop/scc-access.json on the hub.')

def prepare_etcd():
 preflight();hub=CFG['hub_context'];apply(hub,sets(DEMONS),'etcd-scope')
 label_cluster(CFG['prod_cluster'],'workshop.rhacm.io/finale','true')
 api={'apiVersion':'config.openshift.io/v1','kind':'APIServer','metadata':{'name':'cluster'},'spec':{'encryption':{'type':'aesgcm'}}}
 pol=policy(DEMONS,'ws-etcd-encryption',[cp('ws-etcd-setting',[api],'inform')],'inform')
 save('etcd-audit',[pol,placement(DEMONS,'ws-etcd-target',prod=True),binding(DEMONS,'ws-etcd-binding','ws-etcd-target',['ws-etcd-encryption'])])
 print('Generated an INFORM-only policy. Review .workshop/etcd-audit.json, then apply on hub. No encryption setting was changed.')

def cleanup(which):
 # Delete only named, labelled workshop objects. Engine installation is retained.
 hub=CFG['hub_context']
 scopes={'gatekeeper':GKNS,'capstone':CAPNS,'demos':DEMONS}
 ns=scopes[which]
 def delete(ctx,kind,name,namespace=None):
  old=get(ctx,kind,name,namespace)
  if not old:return
  if old['metadata'].get('labels',{}).get(KEY)!=OWNER:fail('Cleanup stopped: unowned '+kind+'/'+name)
  print(oc(ctx,'delete',kind,name,*(['-n',namespace] if namespace else []),'--wait=true','--timeout=120s').stdout,end='')
 # Remove desired state first and wait for replicated Policies to disappear.
 old=get(hub,'policies',namespace=ns)
 if old:
  for p in old['items']:
   if p['metadata'].get('labels',{}).get(KEY)==OWNER:
    name=p['metadata']['name'];delete(hub,'policy',name,ns)
    for role in ['stage','prod']:
     remote=CFG[role+'_cluster']; replica=ns+'.'+name
     wait_for('Replicated policy removed: '+remote+'/'+replica,lambda remote=remote,replica=replica: get(hub,'policy',replica,remote) is None)
 if which=='gatekeeper':
  for role in ['stage','prod']:
   ctx=CFG[role+'_context'];delete(ctx,'WsContainerTags','ws-no-latest');delete(ctx,'ConstraintTemplate','wscontainertags')
  for role,names in [('stage',['ws-stage','ws-stage-exempt']),('prod',['ws-prod'])]:
   for n in names:delete(CFG[role+'_context'],'namespace',n)
  print('Remove only ws-stage-exempt from the Gatekeeper installation policy exclusions if added. Keep the engine and other exclusions.')
 elif which=='capstone':
  delete(CFG['prod_context'],'namespace','ws-app');delete(hub,'managedclusterset',PRODSET)
 elif which=='demos':
  delete(CFG['prod_context'],'namespace','ws-scc');delete(CFG['prod_context'],'securitycontextconstraints','ws-fixed-uid')
  print('No encryption rollback performed. Deleting an inform policy does not alter etcd encryption.')
 delete(hub,'namespace',ns)
 print('Cleanup complete for',which,'. Run restore-labels only AFTER all labs and demos finish.')

def restore_labels():
 for ns in [GKNS,CAPNS,DEMONS,'ws-engine']:
  if get(CFG['hub_context'],'namespace',ns):fail('Clean up '+ns+' before restoring shared scope labels')
 f=STATE/'original-labels.json'
 if f.exists():
  originals=json.loads(f.read_text())
  for name,labels in originals.items():
   for key,val in labels.items():print(oc(CFG['hub_context'],'label','managedcluster',name,key+'-' if val is None else key+'='+val,'--overwrite').stdout,end='')
 # This lab-only label is introduced manually during capstone; remove only expected value.
 m=get(CFG['hub_context'],'managedcluster',CFG['prod_cluster'])
 if m['metadata'].get('labels',{}).get('workshop.rhacm.io/environment')=='production':print(oc(CFG['hub_context'],'label','managedcluster',CFG['prod_cluster'],'workshop.rhacm.io/environment-').stdout)
 old=get(CFG['hub_context'],'managedclusterset',SET)
 if old and old['metadata'].get('labels',{}).get(KEY)==OWNER:print(oc(CFG['hub_context'],'delete','managedclusterset',SET).stdout)
 print('Shared scope cleaned. Original exclusive ClusterSet membership was never modified.')


def prepare_engine():
 preflight();hub=CFG['hub_context']
 for role in ['stage','prod']:
  ctx=CFG[role+'_context']
  crds=get(ctx,'customresourcedefinitions')['items']
  if any(x['metadata']['name']=='gatekeepers.operator.gatekeeper.sh' for x in crds):
   fail('Existing Gatekeeper installation on '+role+'. Instructor must review/reuse it manually. This installer never adopts an existing engine.')
  package=get(ctx,'packagemanifest',CFG['gatekeeper_package'],CFG['gatekeeper_catalog_namespace'])
  if not package or CFG['gatekeeper_channel'] not in [x['name'] for x in package.get('status',{}).get('channels',[])]:fail('Configured Gatekeeper package/channel unavailable on '+role)
 apply(hub,sets('ws-engine'),'engine-scope')
 for role in ['stage','prod']:label_cluster(CFG[role+'_cluster'],'workshop.rhacm.io/finale','true')
 op=obj('OperatorPolicy','ws-install-gatekeeper',{'remediationAction':'enforce','severity':'medium','complianceType':'musthave','upgradeApproval':'Automatic','subscription':{'name':CFG['gatekeeper_package'],'namespace':'openshift-operators','channel':CFG['gatekeeper_channel'],'source':CFG['gatekeeper_catalog'],'sourceNamespace':CFG['gatekeeper_catalog_namespace']}},api='policy.open-cluster-management.io/v1beta1')
 gk=obj('Gatekeeper','gatekeeper',{'audit':{'replicas':1,'logLevel':'INFO'},'validatingWebhook':'Enabled','mutatingWebhook':'Disabled','webhook':{'replicas':2,'logLevel':'INFO','emitAdmissionEvents':'Enabled'},'config':{'disableDefaultMatches':False,'matches':[]}},api='operator.gatekeeper.sh/v1alpha1')
 pol=policy('ws-engine','ws-gatekeeper-engine',[op,cp('ws-gatekeeper-runtime',[gk],'enforce')],'enforce')
 docs=[pol,placement('ws-engine','ws-engine-targets'),binding('ws-engine','ws-engine-binding','ws-engine-targets',['ws-gatekeeper-engine'])]
 save('engine-install',docs)
 variant=copy.deepcopy(docs)
 variant[0]['spec']['policy-templates'][1]['objectDefinition']['spec']['object-templates'][0]['objectDefinition']['spec']['config']['matches']=[{'excludedNamespaces':['ws-stage-exempt'],'processes':['*']}]
 save('engine-with-exclusion',variant)
 print('Engine scope prepared. Review .workshop/engine-install.json, apply on HUB, then check engine-ready. Installation has not been applied automatically.')

def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare-engine','preflight','engine-ready','prepare-gatekeeper','check-gatekeeper','prepare-capstone','check-capstone','prepare-scc','prepare-etcd','cleanup','restore-labels','network']);p.add_argument('extra',nargs='*');a=p.parse_args();cfg()
 actions={'prepare-engine':prepare_engine,'preflight':preflight,'engine-ready':engine_ready,'prepare-gatekeeper':prepare_gk,'check-gatekeeper':check_gk,'prepare-capstone':prepare_capstone,'check-capstone':check_capstone,'prepare-scc':prepare_scc,'prepare-etcd':prepare_etcd,'restore-labels':restore_labels}
 if a.action=='cleanup':cleanup(a.extra[0])
 elif a.action=='network':netcheck(*a.extra)
 else:actions[a.action]()
if __name__=='__main__':
 try:main()
 except (RuntimeError,KeyError,IndexError) as e:print('STOP:',e,file=sys.stderr);sys.exit(1)
