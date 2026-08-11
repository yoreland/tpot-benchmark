import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm

fp = fm.FontProperties(fname='/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc')
plt.rcParams['axes.unicode_minus'] = False

C=[1,4,8,16,32]
# --- self-hosted DeepSeek-V4-Flash, real 40K in / 1.5K out, +EAGLE ---
cfgs = {
 'B300 tp=8':  {'tpot':[3.45,4.04,4.92,8.73,16.66],'ttft':[245,256,274,696,1123],
                'e2e':[5421.8,6381.9,7748.0,14141.7,26571.5],'thru':[272.5,916.8,1356.8,1723.1,1754.1],
                'c':'#4C72B0','m':'o'},
 'B300 2P2D':  {'tpot':[3.75,4.28,4.53,5.12,5.66],'ttft':[1066,1106,1323,1967,4368],
                'e2e':[6583,7295,7716,9635,13124],'thru':[227,712,1358,2187,3361],
                'c':'#55A868','m':'s'},
 'B300 3P1D':  {'tpot':[3.71,4.37,5.14,6.14,6.99],'ttft':[1078,1341,1328,1824,3437],
                'e2e':[6633,8057,8921,10996,14165],'thru':[228,669,1246,1947,3090],
                'c':'#C44E52','m':'^'},
 'H200 tp=8':  {'tpot':[3.15,5.04,7.86,18.36,34.32],'ttft':[1472,1472,1377,1782,2523],
                'e2e':[6138,8858,12072,30122,54242],'thru':[244,660,911,789,869],
                'c':'#8172B3','m':'D'},
}
# --- Bedrock GPT-5.6-Luna: STREAMING, ALIGNED spec 40K in / ~1.5K out (same as V4-Flash) ---
LUNA_TPOT_MS=5.79   # per-token, streaming, 40K in / 1467 out
LUNA_TTFT_MS=1390   # ms
LUNA_E2E_MS=14910   # ms (whole request, ~1467 tok output)

fig, ax = plt.subplots(2,2, figsize=(16,12))
fig.suptitle('综合对比：B300(tp8/2P2D/3P1D) + H200(tp8) + Bedrock GPT-5.6-Luna\n'
             '统一口径 40K in / 1.5K out +EAGLE  ·  Luna 为托管API(流式实测，同口径，橙色参考线)',
             fontproperties=fp, fontsize=15, fontweight='bold')

def line(a,key,title,ylabel,reqline=None,reqlabel=None,luna_ms=None,luna_lab=None):
    for name,d in cfgs.items():
        y=d[key]
        a.plot(C,y,marker=d['m'],color=d['c'],lw=2,ms=7,label=name)
    if reqline:
        a.axhline(reqline,color='red',ls='--',lw=1.2)
        a.text(C[0],reqline,reqlabel,color='red',fontproperties=fp,fontsize=9,va='bottom')
    if luna_ms is not None:
        a.axhline(luna_ms,color='#E8A33D',ls=':',lw=2.2)
        a.text(C[-1],luna_ms,luna_lab,color='#B8791F',fontproperties=fp,fontsize=9,va='bottom',ha='right')
    a.set_title(title,fontproperties=fp,fontsize=12,fontweight='bold')
    a.set_xlabel('并发数 (concurrency)',fontproperties=fp,fontsize=10)
    a.set_ylabel(ylabel,fontproperties=fp,fontsize=10)
    a.set_xscale('log',base=2); a.set_xticks(C); a.set_xticklabels(C)
    a.legend(prop=fp,fontsize=9,ncol=2); a.grid(alpha=0.3)

line(ax[0,0],'tpot','TPOT P50（每 token 延迟）越低越好','ms',4.5,'需求线 4.5ms',
     luna_ms=LUNA_TPOT_MS, luna_lab='Luna TPOT≈5.8ms')
line(ax[0,1],'ttft','TTFT P50（首 token 延迟）越低越好','ms',1700,'需求线 1.7s',
     luna_ms=LUNA_TTFT_MS, luna_lab='Luna TTFT≈1.39s')
line(ax[1,0],'e2e','E2E P50（端到端延迟）越低越好','ms',
     luna_ms=LUNA_E2E_MS, luna_lab='Luna E2E≈14.9s(40K/1.5K)')
line(ax[1,1],'thru','输出吞吐（Output Throughput）越高越好','tokens/s')

plt.tight_layout(rect=[0,0,1,0.94])
out='/home/ubuntu/.openclaw/workspace/all5_combined_compare.png'
plt.savefig(out,dpi=130,bbox_inches='tight')
print('saved',out)
