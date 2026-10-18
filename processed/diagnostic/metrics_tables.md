## Validity gate
- PASS: total rows (3 x 144) (432)
- PASS: all personas in selected 12
- PASS: no null candidate_id on valid_choice
- PASS: every candidate_id in its race list
- PASS: status vocabulary (['undecided', 'valid_choice'])
- PASS: repeats are {1,2,3}
- PASS: 40 C0 cache-hit rows identical to pilot (mismatches=0)

## Execution
| condition | rows | HTTP submitted | cache hits | in tok | out tok | actual billed |
|---|---|---|---|---|---|---|
| C0_ballot | 144 | 104 | 40 | 89,211 | 2,974 | $0.0090367 |
| C1_randA | 144 | 144 | 0 | 89,211 | 2,977 | $0.0124417 |
| C2_randB | 144 | 144 | 0 | 89,211 | 2,943 | $0.0124268 |

- diagnostic total actual billed: $0.0339052
- pilot actual billed:            $0.0034062
- cumulative (pilot + diagnostic): $0.0373114 of $0.05 budget

## Concentration (mayor; ward aggregated)
| cond | model | valid | U | top-1 (Wilson CI) | winner | H | H/lnK | exp(H) | 1/HHI | pairwise agr (boot CI) | ward mean U | ward mean H | ward valid |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| C0_ballot | gemini-lite | 34 | 1 | 1.000 [0.898,1.000] | MAYOR-009 | -0.000 | -0.000 | 1.00 | 1.00 | 1.000 [1.000,1.000] | 1.18 | 0.116 | 32/36 |
| C0_ballot | gpt-4o-mini | 22 | 1 | 1.000 [0.851,1.000] | MAYOR-009 | -0.000 | -0.000 | 1.00 | 1.00 | 1.000 [1.000,1.000] | 1.25 | 0.145 | 35/36 |
| C1_randA | gemini-lite | 34 | 1 | 1.000 [0.898,1.000] | MAYOR-009 | -0.000 | -0.000 | 1.00 | 1.00 | 1.000 [1.000,1.000] | 1.50 | 0.304 | 36/36 |
| C1_randA | gpt-4o-mini | 27 | 1 | 1.000 [0.875,1.000] | MAYOR-009 | -0.000 | -0.000 | 1.00 | 1.00 | 1.000 [1.000,1.000] | 1.33 | 0.212 | 35/36 |
| C2_randB | gemini-lite | 36 | 1 | 1.000 [0.904,1.000] | MAYOR-009 | -0.000 | -0.000 | 1.00 | 1.00 | 1.000 [1.000,1.000] | 1.58 | 0.357 | 36/36 |
| C2_randB | gpt-4o-mini | 25 | 1 | 1.000 [0.867,1.000] | MAYOR-009 | -0.000 | -0.000 | 1.00 | 1.00 | 1.000 [1.000,1.000] | 1.67 | 0.400 | 34/36 |

## Order sensitivity (mayor)
| cond | model | valid | rank-1 capture | top-3 capture | mean rank (null) | median | Spearman pos~freq | winner share |
|---|---|---|---|---|---|---|---|---|
| C0_ballot | gemini-lite | 34 | 0/34 (≈0.019 null) | 0/34 (≈0.057 null) | 9.0 (27.0) | 9 | -0.163 | 1.000 |
| C0_ballot | gpt-4o-mini | 22 | 0/22 (≈0.019 null) | 0/22 (≈0.057 null) | 9.0 (27.0) | 9 | -0.163 | 1.000 |
| C1_randA | gemini-lite | 34 | 0/34 (≈0.019 null) | 0/34 (≈0.057 null) | 14.5 (27.0) | 17 | -0.199 | 1.000 |
| C1_randA | gpt-4o-mini | 27 | 0/27 (≈0.019 null) | 11/27 (≈0.057 null) | 19.0 (27.0) | 20 | -0.118 | 1.000 |
| C2_randB | gemini-lite | 36 | 0/36 (≈0.019 null) | 0/36 (≈0.057 null) | 36.3 (27.0) | 30 | +0.154 | 1.000 |
| C2_randB | gpt-4o-mini | 25 | 0/25 (≈0.019 null) | 0/25 (≈0.057 null) | 39.5 (27.0) | 42 | +0.190 | 1.000 |

### Cross-condition switch rates & winner invariance
| condition pair | race | same | diff | switch rate |
|---|---|---|---|---|
| C0_ballot vs C1_randA | mayor | 53 | 0 | 0.000 |
| C0_ballot vs C1_randA | ward | 47 | 19 | 0.288 |
| C0_ballot vs C2_randB | mayor | 51 | 0 | 0.000 |
| C0_ballot vs C2_randB | ward | 47 | 18 | 0.277 |
| C1_randA vs C2_randB | mayor | 56 | 0 | 0.000 |
| C1_randA vs C2_randB | ward | 46 | 23 | 0.333 |
- winner invariant across all 3 conditions (mayor): 49/49 = 1.000
- winner invariant across all 3 conditions (ward): 38/64 = 0.594

## Provider differences
| cond | gemini undecided (Wilson) | gpt undecided (Wilson) | Fisher p (valid vs undec) | cross-provider agree mayor | ward |
|---|---|---|---|---|---|
| C0_ballot | 6/72 = 0.083 [0.039, 0.170] | 15/72 = 0.208 [0.131, 0.316] | 0.0570 | 1.000 (21/21) | 0.625 (20/32) |
| C1_randA | 2/72 = 0.028 [0.008, 0.096] | 10/72 = 0.139 [0.077, 0.237] | 0.0310 | 1.000 (25/25) | 0.600 (21/35) |
| C2_randB | 0/72 = 0.000 [0.000, 0.051] | 13/72 = 0.181 [0.109, 0.285] | 0.0001 | 1.000 (25/25) | 0.588 (20/34) |

## Repeat disagreement (3 pairs per cell)
| cond | model | race | pairs | agree | choice flips | status flips | agree rate (Wilson) |
|---|---|---|---|---|---|---|---|
| C0_ballot | gemini-lite | mayor | 36 | 34 | 0 | 2 | 0.944 [0.819,0.985] |
| C0_ballot | gemini-lite | ward | 36 | 30 | 4 | 2 | 0.833 [0.681,0.921] |
| C0_ballot | gpt-4o-mini | mayor | 36 | 30 | 0 | 6 | 0.833 [0.681,0.921] |
| C0_ballot | gpt-4o-mini | ward | 36 | 29 | 5 | 2 | 0.806 [0.650,0.902] |
| C1_randA | gemini-lite | mayor | 36 | 32 | 0 | 4 | 0.889 [0.747,0.956] |
| C1_randA | gemini-lite | ward | 36 | 25 | 11 | 0 | 0.694 [0.531,0.820] |
| C1_randA | gpt-4o-mini | mayor | 36 | 30 | 0 | 6 | 0.833 [0.681,0.921] |
| C1_randA | gpt-4o-mini | ward | 36 | 26 | 8 | 2 | 0.722 [0.560,0.842] |
| C2_randB | gemini-lite | mayor | 36 | 36 | 0 | 0 | 1.000 [0.904,1.000] |
| C2_randB | gemini-lite | ward | 36 | 23 | 13 | 0 | 0.639 [0.476,0.775] |
| C2_randB | gpt-4o-mini | mayor | 36 | 26 | 0 | 10 | 0.722 [0.560,0.842] |
| C2_randB | gpt-4o-mini | ward | 36 | 19 | 13 | 4 | 0.528 [0.370,0.680] |

## Demographic marginals (mayor)
| cond | model | attr | group | personas | valid/total | undec | U | top-1 | H | JSD vs pooled |
|---|---|---|---|---|---|---|---|---|---|---|
| C0_ballot | gemini-lite | age | 20-29 | 3 | 7/9 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gemini-lite | age | 30-44 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gemini-lite | age | 45-64 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gemini-lite | age | 65+ | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gemini-lite | education | High school or less | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gemini-lite | education | Postsecondary below bachelor's | 4 | 10/12 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gemini-lite | education | Bachelor's degree or higher | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gpt-4o-mini | age | 20-29 | 3 | 6/9 | 3 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gpt-4o-mini | age | 30-44 | 3 | 6/9 | 3 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gpt-4o-mini | age | 45-64 | 3 | 7/9 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gpt-4o-mini | age | 65+ | 3 | 3/9 | 6 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gpt-4o-mini | education | High school or less | 4 | 2/12 | 10 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gpt-4o-mini | education | Postsecondary below bachelor's | 4 | 8/12 | 4 | 1 | 1.000 | -0.000 | 0.0000 |
| C0_ballot | gpt-4o-mini | education | Bachelor's degree or higher | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gemini-lite | age | 20-29 | 3 | 7/9 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gemini-lite | age | 30-44 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gemini-lite | age | 45-64 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gemini-lite | age | 65+ | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gemini-lite | education | High school or less | 4 | 11/12 | 1 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gemini-lite | education | Postsecondary below bachelor's | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gemini-lite | education | Bachelor's degree or higher | 4 | 11/12 | 1 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gpt-4o-mini | age | 20-29 | 3 | 7/9 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gpt-4o-mini | age | 30-44 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gpt-4o-mini | age | 45-64 | 3 | 7/9 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gpt-4o-mini | age | 65+ | 3 | 4/9 | 5 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gpt-4o-mini | education | High school or less | 4 | 6/12 | 6 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gpt-4o-mini | education | Postsecondary below bachelor's | 4 | 9/12 | 3 | 1 | 1.000 | -0.000 | 0.0000 |
| C1_randA | gpt-4o-mini | education | Bachelor's degree or higher | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gemini-lite | age | 20-29 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gemini-lite | age | 30-44 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gemini-lite | age | 45-64 | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gemini-lite | age | 65+ | 3 | 9/9 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gemini-lite | education | High school or less | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gemini-lite | education | Postsecondary below bachelor's | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gemini-lite | education | Bachelor's degree or higher | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gpt-4o-mini | age | 20-29 | 3 | 7/9 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gpt-4o-mini | age | 30-44 | 3 | 8/9 | 1 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gpt-4o-mini | age | 45-64 | 3 | 7/9 | 2 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gpt-4o-mini | age | 65+ | 3 | 3/9 | 6 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gpt-4o-mini | education | High school or less | 4 | 7/12 | 5 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gpt-4o-mini | education | Postsecondary below bachelor's | 4 | 6/12 | 6 | 1 | 1.000 | -0.000 | 0.0000 |
| C2_randB | gpt-4o-mini | education | Bachelor's degree or higher | 4 | 12/12 | 0 | 1 | 1.000 | -0.000 | 0.0000 |

## Ward-race undecided rate by demographic group
| cond | model | attr | group | undec/total | rate |
|---|---|---|---|---|---|
| C0_ballot | gemini-lite | age | 20-29 | 1/9 | 0.111 |
| C0_ballot | gemini-lite | age | 30-44 | 0/9 | 0.000 |
| C0_ballot | gemini-lite | age | 45-64 | 0/9 | 0.000 |
| C0_ballot | gemini-lite | age | 65+ | 3/9 | 0.333 |
| C0_ballot | gemini-lite | education | High school or less | 0/12 | 0.000 |
| C0_ballot | gemini-lite | education | Postsecondary below bachelor's | 4/12 | 0.333 |
| C0_ballot | gemini-lite | education | Bachelor's degree or higher | 0/12 | 0.000 |
| C0_ballot | gpt-4o-mini | age | 20-29 | 0/9 | 0.000 |
| C0_ballot | gpt-4o-mini | age | 30-44 | 0/9 | 0.000 |
| C0_ballot | gpt-4o-mini | age | 45-64 | 0/9 | 0.000 |
| C0_ballot | gpt-4o-mini | age | 65+ | 1/9 | 0.111 |
| C0_ballot | gpt-4o-mini | education | High school or less | 0/12 | 0.000 |
| C0_ballot | gpt-4o-mini | education | Postsecondary below bachelor's | 1/12 | 0.083 |
| C0_ballot | gpt-4o-mini | education | Bachelor's degree or higher | 0/12 | 0.000 |
| C1_randA | gemini-lite | age | 20-29 | 0/9 | 0.000 |
| C1_randA | gemini-lite | age | 30-44 | 0/9 | 0.000 |
| C1_randA | gemini-lite | age | 45-64 | 0/9 | 0.000 |
| C1_randA | gemini-lite | age | 65+ | 0/9 | 0.000 |
| C1_randA | gemini-lite | education | High school or less | 0/12 | 0.000 |
| C1_randA | gemini-lite | education | Postsecondary below bachelor's | 0/12 | 0.000 |
| C1_randA | gemini-lite | education | Bachelor's degree or higher | 0/12 | 0.000 |
| C1_randA | gpt-4o-mini | age | 20-29 | 0/9 | 0.000 |
| C1_randA | gpt-4o-mini | age | 30-44 | 0/9 | 0.000 |
| C1_randA | gpt-4o-mini | age | 45-64 | 1/9 | 0.111 |
| C1_randA | gpt-4o-mini | age | 65+ | 0/9 | 0.000 |
| C1_randA | gpt-4o-mini | education | High school or less | 1/12 | 0.083 |
| C1_randA | gpt-4o-mini | education | Postsecondary below bachelor's | 0/12 | 0.000 |
| C1_randA | gpt-4o-mini | education | Bachelor's degree or higher | 0/12 | 0.000 |
| C2_randB | gemini-lite | age | 20-29 | 0/9 | 0.000 |
| C2_randB | gemini-lite | age | 30-44 | 0/9 | 0.000 |
| C2_randB | gemini-lite | age | 45-64 | 0/9 | 0.000 |
| C2_randB | gemini-lite | age | 65+ | 0/9 | 0.000 |
| C2_randB | gemini-lite | education | High school or less | 0/12 | 0.000 |
| C2_randB | gemini-lite | education | Postsecondary below bachelor's | 0/12 | 0.000 |
| C2_randB | gemini-lite | education | Bachelor's degree or higher | 0/12 | 0.000 |
| C2_randB | gpt-4o-mini | age | 20-29 | 0/9 | 0.000 |
| C2_randB | gpt-4o-mini | age | 30-44 | 0/9 | 0.000 |
| C2_randB | gpt-4o-mini | age | 45-64 | 0/9 | 0.000 |
| C2_randB | gpt-4o-mini | age | 65+ | 2/9 | 0.222 |
| C2_randB | gpt-4o-mini | education | High school or less | 1/12 | 0.083 |
| C2_randB | gpt-4o-mini | education | Postsecondary below bachelor's | 1/12 | 0.083 |
| C2_randB | gpt-4o-mini | education | Bachelor's degree or higher | 0/12 | 0.000 |

metrics.json -> /Users/zhongjingwen/Desktop/MScAC/STA2453/toronto-election-forecast/processed/diagnostic/metrics.json
