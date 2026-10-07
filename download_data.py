import urllib.request,json,pathlib,concurrent.futures,hashlib,datetime
ROOT=pathlib.Path(__file__).parent
BASE='https://ckan0.cf.opendata.inter.prod-toronto.ca/api/3/action/package_show?id='
items=[]
for n,select,role in [
 ('ward-profiles-25-ward-model',lambda r:True,'core'),
 ('wards-and-elected-councillors',lambda r:r['url'].endswith('4326.geojson'),'core'),
 ('elected-officials-contact-information',lambda r:r['url'].endswith('2022-2026-elected-officials-contact-info.json'),'core'),
 ('election-results-official',lambda r:r['name']=='2022-results','historical_optional'),
 ('elections-voter-statistics',lambda r:r['name']=='2022-voter-statistics','historical_optional'),
 ('elections-official-by-election-results',lambda r:'2023 Office of the Mayor'==r['name'] or ('Councillor' in r['name'] and any(y in r['name'] for y in ['2023','2024','2025'])),'historical_optional')]:
 p=json.load(urllib.request.urlopen(BASE+n,timeout=45))['result']
 (ROOT/'raw'/f'{n}_metadata.json').write_text(json.dumps(p,ensure_ascii=False,indent=2))
 for r in p['resources']:
  if select(r):items.append(dict(name=r['name'],url=r['url'],source_website='https://open.toronto.ca/dataset/'+n+'/',role=role,license=p.get('license_title')))
for f in ['mayorCandidates_2026.json','councilorCandidates_2026.json','withdrawnCandidates_2026.json']:
 items.append(dict(name=f,url='https://www.toronto.ca/data/elections/candidate_list/'+f,source_website='https://www.toronto.ca/city-government/elections/candidate-list/',role='core',license='City website terms; check before redistribution'))
def dl(i):
 try:
  b=urllib.request.urlopen(i['url'],timeout=60).read(); path=ROOT/'raw'/i['role']/i['url'].split('/')[-1];path.parent.mkdir(exist_ok=True);path.write_bytes(b)
  i.update(file=str(path.relative_to(ROOT)),bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),downloaded_at=datetime.datetime.now(datetime.timezone.utc).isoformat());print(path.name,len(b),flush=True)
 except Exception as e:i['error']=str(e);print('FAILED',i['name'],e,flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:list(ex.map(dl,items))
(ROOT/'sources.json').write_text(json.dumps(items,ensure_ascii=False,indent=2))
