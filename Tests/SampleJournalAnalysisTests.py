import copy, importlib.util, json, unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('journal',Path(__file__).resolve().parents[1]/'scripts/reconstruct-sample-journal.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def fixture():
 rows=[{'sequence':i,'sample':{'seconds':i+1,'framesDecoded':i*60}} for i in range(10)]
 report={'mode':'viewer','samples':[x['sample'] for x in rows[-3:]],'sampleJournal':{'closed':True,'pending':0,'dropped':0,'writeFailures':0,'written':10,'submitted':10}}
 return report,rows
def encoded(rows):return b''.join(json.dumps(r).encode()+b'\n' for r in rows)
class JournalAnalysisTests(unittest.TestCase):
 def test_recover_complete_history(self):
  report,rows=fixture(); result=m.reconstruct(report,encoded(rows));self.assertEqual(len(result['samples']),10);self.assertEqual(result['sampleJournalReconstruction']['originalRetainedRecords'],3)
 def test_missing_record(self):
  report,rows=fixture();rows.pop(3)
  with self.assertRaises(ValueError):m.reconstruct(report,encoded(rows))
 def test_wrong_tail(self):
  report,rows=fixture();report=copy.deepcopy(report);report['samples'][-1]['framesDecoded']+=1
  with self.assertRaises(ValueError):m.reconstruct(report,encoded(rows))
 def test_failed_or_unclosed_writer(self):
  for field,value in [('dropped',1),('pending',1),('writeFailures',1),('closed',False),('written',9)]:
   with self.subTest(field=field):
    report,rows=fixture();report['sampleJournal'][field]=value
    with self.assertRaises(ValueError):m.reconstruct(report,encoded(rows))
 def test_epoch_reset(self):
  report,rows=fixture();rows[4]['sample']['framesDecoded']=1
  with self.assertRaises(ValueError):m.reconstruct(report,encoded(rows))
 def test_incomplete_last_line(self):
  report,rows=fixture()
  with self.assertRaises(ValueError):m.reconstruct(report,encoded(rows)[:-1])
if __name__=='__main__':unittest.main()
