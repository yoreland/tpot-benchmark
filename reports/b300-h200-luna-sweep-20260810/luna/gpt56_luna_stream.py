#!/usr/bin/env python3
"""GPT-5.6-Luna 流式基准：真实测 TTFT / TPOT / E2E。
Bedrock Mantle Responses API (SSE), us-east-1, SigV4 service=bedrock-mantle。
TTFT = 首个输出 token 到达时间; TPOT = (E2E - TTFT)/(out_tokens-1)。"""
import json, urllib.request, urllib.error, time, statistics
from botocore.session import Session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION="us-east-1"
URL=f"https://bedrock-mantle.{REGION}.api.aws/openai/v1/responses"
MODEL="openai.gpt-5.6-luna"
ROUNDS=3
# 让它生成较长输出，TPOT 才稳定有意义
PROMPTS=[
  ("长文生成-架构",
   "Write a detailed ~600-word explanation of AWS Well-Architected Framework's five pillars, with concrete examples for each pillar."),
  ("长文生成-对比",
   "Explain in ~600 words the differences between Amazon EC2, ECS, EKS, and Lambda, including when to use each, with trade-offs."),
  ("长文生成-中文",
   "用大约600字详细说明什么是检索增强生成(RAG)，包括其工作流程、关键组件、优势与局限，以及在企业知识库场景下的落地建议。"),
]

def call_stream(model, prompt, max_tokens=1200, timeout=180):
    payload={"model":model,"input":prompt,"stream":True,
             "reasoning":{"effort":"low"},"max_output_tokens":max_tokens}
    data=json.dumps(payload).encode()
    creds=Session().get_credentials().get_frozen_credentials()
    req=AWSRequest(method="POST",url=URL,data=data,
                   headers={"Content-Type":"application/json","Accept":"text/event-stream"})
    SigV4Auth(creds,"bedrock-mantle",REGION).add_auth(req)
    r=urllib.request.Request(URL,data=data,headers=dict(req.headers),method="POST")
    t0=time.time(); ttft=None; token_times=[]; text=""; out_tokens=0; usage={}
    try:
        resp=urllib.request.urlopen(r,timeout=timeout)
        for raw in resp:
            line=raw.decode("utf-8","ignore").strip()
            if not line or not line.startswith("data:"): continue
            payload_str=line[5:].strip()
            if payload_str=="[DONE]": break
            try: ev=json.loads(payload_str)
            except: continue
            et=ev.get("type","")
            # output_text delta events carry incremental text
            if et.endswith("output_text.delta") or et=="response.output_text.delta":
                d=ev.get("delta","")
                if d:
                    now=time.time()
                    if ttft is None: ttft=now-t0
                    token_times.append(now); text+=d
            # final usage on completed event
            if et.endswith("completed") or et=="response.completed":
                u=(ev.get("response",{}) or {}).get("usage",{}) or ev.get("usage",{}) or {}
                if u: usage=u
        e2e=time.time()-t0
        out_tokens=usage.get("output_tokens",0) or len(token_times)
        # TPOT: inter-token from first to last delta / (n-1)
        if len(token_times)>=2:
            tpot_ms=(token_times[-1]-token_times[0])/(len(token_times)-1)*1000
        else:
            tpot_ms=0
        return {"ok":True,"ttft":ttft if ttft else 0,"e2e":e2e,"tpot_ms":tpot_ms,
                "deltas":len(token_times),"out":out_tokens,
                "in":usage.get("input_tokens",0),"chars":len(text),"sample":text[:80]}
    except urllib.error.HTTPError as e:
        return {"ok":False,"err":f"HTTP {e.code}: {e.read().decode()[:150]}"}
    except Exception as e:
        return {"ok":False,"err":f"{type(e).__name__}: {str(e)[:150]}"}

if __name__=="__main__":
    print(f"model={MODEL} region={REGION} STREAMING rounds/task={ROUNDS}")
    print("="*94)
    all_ttft=[]; all_tpot=[]; all_e2e=[]; all_out=[]
    per={}
    for tname,prompt in PROMPTS:
        ttfts=[]; tpots=[]; e2es=[]; outs=[]; deltas=0; sample=""
        for k in range(ROUNDS):
            r=call_stream(MODEL,prompt)
            if not r["ok"]:
                print(f"  {tname:14} round{k+1} FAIL: {r['err']}"); continue
            ttfts.append(r["ttft"]); tpots.append(r["tpot_ms"]); e2es.append(r["e2e"]); outs.append(r["out"])
            deltas=r["deltas"]
            if not sample: sample=r["sample"].replace("\n"," ")
            time.sleep(0.4)
        if ttfts:
            all_ttft+=ttfts; all_tpot+=tpots; all_e2e+=e2es; all_out+=outs
            per[tname]={"ttft_p50":round(statistics.median(ttfts),3),
                        "tpot_p50_ms":round(statistics.median(tpots),2),
                        "e2e_p50":round(statistics.median(e2es),2),
                        "out_mean":round(statistics.mean(outs)),"deltas":deltas}
            print(f"  {tname:14} TTFT_p50={statistics.median(ttfts):.2f}s  "
                  f"TPOT_p50={statistics.median(tpots):.1f}ms  E2E_p50={statistics.median(e2es):.2f}s  "
                  f"out~{statistics.mean(outs):.0f} deltas={deltas}")
    print("\n"+"="*94)
    if all_ttft:
        def p(v,q): return sorted(v)[max(0,int(len(v)*q)-1)]
        print("【GPT-5.6-Luna 流式 总体】", f"{len(all_ttft)} 次调用")
        print(f"  TTFT  P50/P95 : {statistics.median(all_ttft):.2f}s / {p(all_ttft,0.95):.2f}s")
        print(f"  TPOT  P50/P95 : {statistics.median(all_tpot):.1f}ms / {p(all_tpot,0.95):.1f}ms")
        print(f"  E2E   P50/P95 : {statistics.median(all_e2e):.2f}s / {p(all_e2e,0.95):.2f}s")
        print(f"  输出token 均值 : {statistics.mean(all_out):.0f}")
        json.dump({"model":MODEL,"mode":"streaming","per_task":per,
                   "overall":{"calls":len(all_ttft),
                              "ttft_p50_s":round(statistics.median(all_ttft),3),
                              "tpot_p50_ms":round(statistics.median(all_tpot),2),
                              "e2e_p50_s":round(statistics.median(all_e2e),2),
                              "out_mean":round(statistics.mean(all_out),1)}},
                  open("/tmp/gpt56_luna_stream.json","w"),ensure_ascii=False,indent=2)
        print("\n结果已存 /tmp/gpt56_luna_stream.json")
