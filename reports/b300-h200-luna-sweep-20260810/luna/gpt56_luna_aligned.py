#!/usr/bin/env python3
"""GPT-5.6-Luna 对齐 V4-Flash 口径的流式基准：40K input / 1.5K output。
Bedrock Mantle Responses API (SSE), us-east-1, SigV4 service=bedrock-mantle。
TTFT=首delta; TPOT=(last-first)/(n-1); E2E=总时长。"""
import json, urllib.request, urllib.error, time, statistics
from botocore.session import Session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION="us-east-1"
URL=f"https://bedrock-mantle.{REGION}.api.aws/openai/v1/responses"
MODEL="openai.gpt-5.6-luna"
ROUNDS=3
TARGET_IN=40000     # tokens
TARGET_OUT=1500     # tokens

# ~40K token 的稳定长上下文（英文约 0.75 词/token → ~30000 词）。用一段技术文本重复堆到目标长度。
BASE=("Amazon Web Services provides a broad set of cloud services including compute, "
      "storage, networking, databases, analytics, machine learning, security, and "
      "developer tools. The Well-Architected Framework describes best practices across "
      "operational excellence, security, reliability, performance efficiency, cost "
      "optimization, and sustainability. ")
# 1 word ~= 1.3 token 粗估；40000 token ~= 30800 词。BASE ~50 词 → 需要约 620 段。多堆点保证到量。
def build_input():
    ctx=(BASE*700)
    task=("\n\nBased on the reference material above, write a comprehensive ~1500-token "
          "technical report covering: (1) an overview of the AWS Well-Architected "
          "Framework, (2) a detailed explanation of all six pillars with concrete "
          "examples, (3) trade-offs between cost optimization and performance, and "
          "(4) a step-by-step adoption roadmap for an enterprise. Write in detail, "
          "aim for about 1500 tokens of output.")
    return ctx+task

def call_stream(prompt, max_tokens=TARGET_OUT, timeout=300):
    payload={"model":MODEL,"input":prompt,"stream":True,
             "reasoning":{"effort":"low"},"max_output_tokens":max_tokens}
    data=json.dumps(payload).encode()
    creds=Session().get_credentials().get_frozen_credentials()
    req=AWSRequest(method="POST",url=URL,data=data,
                   headers={"Content-Type":"application/json","Accept":"text/event-stream"})
    SigV4Auth(creds,"bedrock-mantle",REGION).add_auth(req)
    r=urllib.request.Request(URL,data=data,headers=dict(req.headers),method="POST")
    t0=time.time(); ttft=None; tt=[]; text=""; usage={}
    try:
        resp=urllib.request.urlopen(r,timeout=timeout)
        for raw in resp:
            line=raw.decode("utf-8","ignore").strip()
            if not line or not line.startswith("data:"): continue
            ps=line[5:].strip()
            if ps=="[DONE]": break
            try: ev=json.loads(ps)
            except: continue
            et=ev.get("type","")
            if et.endswith("output_text.delta"):
                d=ev.get("delta","")
                if d:
                    now=time.time()
                    if ttft is None: ttft=now-t0
                    tt.append(now); text+=d
            if et.endswith("completed"):
                u=(ev.get("response",{}) or {}).get("usage",{}) or ev.get("usage",{}) or {}
                if u: usage=u
        e2e=time.time()-t0
        out=usage.get("output_tokens",0) or len(tt)
        tpot=(tt[-1]-tt[0])/(len(tt)-1)*1000 if len(tt)>=2 else 0
        return {"ok":True,"ttft":ttft or 0,"e2e":e2e,"tpot_ms":tpot,
                "in":usage.get("input_tokens",0),"out":out,"deltas":len(tt),
                "cached":usage.get("input_tokens_details",{}).get("cached_tokens",0),
                "sample":text[:80]}
    except urllib.error.HTTPError as e:
        return {"ok":False,"err":f"HTTP {e.code}: {e.read().decode()[:200]}"}
    except Exception as e:
        return {"ok":False,"err":f"{type(e).__name__}: {str(e)[:200]}"}

if __name__=="__main__":
    prompt=build_input()
    print(f"model={MODEL} region={REGION} target_in={TARGET_IN} target_out={TARGET_OUT} rounds={ROUNDS}")
    print(f"built input chars={len(prompt)}")
    print("="*90)
    ttfts=[]; tpots=[]; e2es=[]; ins=[]; outs=[]
    for k in range(ROUNDS):
        r=call_stream(prompt)
        if not r["ok"]:
            print(f"  round{k+1} FAIL: {r['err']}"); continue
        ttfts.append(r["ttft"]); tpots.append(r["tpot_ms"]); e2es.append(r["e2e"])
        ins.append(r["in"]); outs.append(r["out"])
        print(f"  round{k+1}: in={r['in']} out={r['out']} cached={r['cached']} deltas={r['deltas']} "
              f"TTFT={r['ttft']:.2f}s TPOT={r['tpot_ms']:.2f}ms E2E={r['e2e']:.2f}s")
        time.sleep(0.5)
    print("\n"+"="*90)
    if ttfts:
        def p(v,q): return sorted(v)[max(0,int(len(v)*q)-1)]
        print(f"【GPT-5.6-Luna · 对齐口径 in~{statistics.mean(ins):.0f}/out~{statistics.mean(outs):.0f}】{len(ttfts)}次")
        print(f"  TTFT P50/P95 : {statistics.median(ttfts):.2f}s / {p(ttfts,0.95):.2f}s")
        print(f"  TPOT P50/P95 : {statistics.median(tpots):.2f}ms / {p(tpots,0.95):.2f}ms")
        print(f"  E2E  P50/P95 : {statistics.median(e2es):.2f}s / {p(e2es,0.95):.2f}s")
        json.dump({"model":MODEL,"mode":"streaming_aligned","target_in":TARGET_IN,"target_out":TARGET_OUT,
                   "in_mean":round(statistics.mean(ins)),"out_mean":round(statistics.mean(outs)),
                   "ttft_p50_s":round(statistics.median(ttfts),3),
                   "tpot_p50_ms":round(statistics.median(tpots),2),
                   "e2e_p50_s":round(statistics.median(e2es),2),"calls":len(ttfts)},
                  open("/tmp/gpt56_luna_aligned.json","w"),ensure_ascii=False,indent=2)
        print("\n结果已存 /tmp/gpt56_luna_aligned.json")
