
 OCR 정확도 harness 시작 — 10개 샘플

  endpoint : http://localhost:18080
  fixtures : tests/accuracy/fixtures
  commit   : 36632cf

  처리 중: biz-license-01.png ... done  char_acc=100.0%  exact=7/7  items=7
  처리 중: biz-license-02.png ... done  char_acc=98.2%  exact=6/7  items=7
  처리 중: contract-01.png ... done  char_acc=88.5%  exact=5/6  items=8
  처리 중: driver-license-01.png ... done  char_acc=98.1%  exact=5/6  items=6
  처리 중: id-korean-01.png ... done  char_acc=98.0%  exact=4/5  items=5
  처리 중: id-korean-02.png ... done  char_acc=96.0%  exact=3/5  items=5
  처리 중: invoice-01.png ... done  char_acc=98.7%  exact=8/9  items=19
  처리 중: mixed-01.png ... done  char_acc=91.2%  exact=3/7  items=11
  처리 중: receipt-01.png ... done  char_acc=97.0%  exact=5/6  items=10
  처리 중: receipt-02.png ... done  char_acc=94.0%  exact=6/8  items=18

╔══════════════════════╤═════════════════╤═══════════╤═══════════╤═════════╤═══════════╤════════╤════════════╗
║ image                │ category        │     exact │       tol │   avg_d │  char_acc │  items │ status     ║
╠══════════════════════╪═════════════════╪═══════════╪═══════════╪═════════╪═══════════╪════════╪════════════╣
║ biz-license-01       │ biz-license     │       7/7 │       7/7 │     0.0 │    100.0% │      7 │ OK         ║
║ biz-license-02       │ biz-license     │       6/7 │       7/7 │     0.1 │     98.2% │      7 │ OK         ║
║ contract-01          │ contract        │       5/6 │       5/6 │     1.0 │     88.5% │      8 │ OK         ║
║ driver-license-01    │ driver-license  │       5/6 │       5/6 │     0.2 │     98.1% │      6 │ OK         ║
║ id-korean-01         │ id-card         │       4/5 │       5/5 │     0.2 │     98.0% │      5 │ OK         ║
║ id-korean-02         │ id-card         │       3/5 │       4/5 │     0.4 │     96.0% │      5 │ OK         ║
║ invoice-01           │ invoice         │       8/9 │       9/9 │     0.1 │     98.7% │     19 │ OK         ║
║ mixed-01             │ mixed           │       3/7 │       5/7 │     1.1 │     91.2% │     11 │ OK         ║
║ receipt-01           │ receipt         │       5/6 │       6/6 │     0.2 │     97.0% │     10 │ OK         ║
║ receipt-02           │ receipt         │       6/8 │       7/8 │     0.4 │     94.0% │     18 │ OK         ║
╠══════════════════════╪═════════════════╪═══════════╪═══════════╪═════════╪═══════════╪════════╪════════════╣
║ SUMMARY (10/10 성공)   │                 │     52/66 │     60/66 │    0.36 │     95.8% │     96 │            ║
╚══════════════════════╧═════════════════╧═══════════╧═══════════╧═════════╧═══════════╧════════╧════════════╝

  exact_match_rate  : 78.8%
  tolerance_rate    : 90.9%
  avg_edit_distance : 0.36
  char_accuracy     : 95.8%
  low_conf_rate     : 8.3%

── 카테고리별 요약 ─────────────────────────────────
  category               n  char_acc  exact_rate
  -------------------- --- --------- -----------
  biz-license            2     99.1%       92.9%
  contract               1     88.5%       83.3%
  driver-license         1     98.1%       83.3%
  id-card                2     97.0%       70.0%
  invoice                1     98.7%       88.9%
  mixed                  1     91.2%       42.9%
  receipt                2     95.2%       78.6%

── 최저 char_accuracy 3개 ──────────────────────────
  contract-01                    char_acc=88.5%  exact=5/6
    key=contract_amount      d= 6  exp='₩5,000,000'  got='계약금액:금오백만원정(버5,OOO,OO0)'
    key=doc_title            d= 0  exp='용역계약서'  got='용역계약서'
    key=party_a              d= 0  exp='주식회사알파테크'  got='갑:주식회사알파테크(이하"갑")'
  mixed-01                       char_acc=91.2%  exact=3/7
    key=doc_title            d= 5  exp='혼합문서/MixedDocument'  got='MixedDocument'
    key=product_name         d= 1  exp='UltraHD모니터27인치(UHD-2700K)'  got='제품명:UltraHD모니터27인치(UHD-270OK)'
    key=price_krw            d= 1  exp='₩399,000'  got='가격:w399,000'
  receipt-02                     char_acc=94.0%  exact=6/8
    key=item1_name           d= 2  exp='생수500mL'  got='생수5OOmL'
    key=item4_name           d= 1  exp='껌(스피아민트)'  got='퍽(스피아민트)'
    key=doc_title            d= 0  exp='영수증'  got='영수증'

  JSON 저장: tests/accuracy/reports/baseline-36632cf.json

