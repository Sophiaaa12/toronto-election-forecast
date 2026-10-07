import csv,json,pathlib,openpyxl,zipfile,collections
p=pathlib.Path(__file__).parent;(p/'processed').mkdir(exist_ok=True)
o=json.load(open(p/'raw/core/2022-2026-elected-officials-contact-info.json'))
inc={('mayor' if x['Primary role']=='Mayor' else 'councillor',0 if x['Primary role']=='Mayor' else int(x['District ID'])): (x['First name']+' '+x['Last name']).casefold() for x in o if x['Primary role'] in ['Mayor','Councillor']}
rows=[]
for office,filename in [('mayor','mayorCandidates_2026.json'),('councillor','councilorCandidates_2026.json')]:
 d=json.load(open(p/'raw/core'/filename));groups=[(0,d['candidates'])] if office=='mayor' else [(int(x['num']),x['candidate']) for x in d['ward']]
 for ward,cs in groups:
  for c in cs:
   name=c['firstName']+' '+c['lastName']
   rows.append(dict(office=office,ward=ward,ballot_name=c['name'],display_name=name,status=c['status'],incumbent_name_match=name.casefold()==inc.get((office,ward)),website=' | '.join(x['url'] for x in c['socialMedias'] if x['name']=='web'),source='https://www.toronto.ca/city-government/elections/candidate-list/'))
with open(p/'processed/candidates_2026.csv','w') as f:
 w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
w=openpyxl.load_workbook(p/'raw/core/25-wardnames-numbers.xlsx',read_only=True,data_only=True)
with open(p/'processed/wards.csv','w') as f:csv.writer(f).writerows(w.active.values)
w=openpyxl.load_workbook(p/'raw/core/2023-wardprofiles-2011-2021-censusdata_rev0719.xlsx',read_only=True,data_only=True)
for s in list(w)[:2]:
 with open(p/'processed'/('census_'+s.title.replace(' ','_').lower()+'.csv'),'w') as f:csv.writer(f).writerows(s.values)
checks={'mayor_candidates':sum(r['office']=='mayor' for r in rows),'councillor_candidates':sum(r['office']=='councillor' for r in rows),'wards':sorted({r['ward'] for r in rows if r['office']=='councillor'}),'map_features':len(json.load(open(p/'raw/core/ward-and-elected-councillor-4326.geojson'))['features']),'download_failures':[x for x in json.load(open(p/'sources.json')) if 'error' in x], 'incumbency_note':'Exact name matches only; manually review spelling and incumbency before modeling.'}
(p/'validation.json').write_text(json.dumps(checks,indent=2))
assert checks['mayor_candidates']==53 and checks['councillor_candidates']==190 and len(checks['wards'])==25 and not checks['download_failures']
print(checks)
