import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
import json

fp = fm.FontProperties(fname='/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc')
plt.rcParams['axes.unicode_minus'] = False

def g(tag,c):
    d=[json.loads(l) for l in open(f'sweep40k/{tag}_sweep40k_c{c}.jsonl')][-1]
    return d
C=[1,4,8,16,32]
data={t:{c:g(t,c) for c in C} for t in ['tp8','2p2d','3p1d']}
names={'tp8':'tp=8','2p2d':'2P2D','3p1d':'3P1D'}
colors={'tp8':'#4C72B0','2p2d':'#55A868','3p1d':'#C44E52'}
mk={'tp8':'o','2p2d':'s','3p1d':'^'}

fig, ax = plt.subplots(2,2, figsize=(15,11))
fig.suptitle('B300 三方案并发扩展性对比 · DeepSeek-V4-Flash · 40K in / 1.5K out / +EAGLE',
             fontproperties=fp, fontsize=16, fontweight='bold')

def line(a,key,title,ylabel,reqline=None,reqlabel=None):
    for t in ['tp8','2p2d','3p1d']:
        y=[data[t][c][key] for c in C]
        a.plot(C,y,marker=mk[t],color=colors[t],lw=2,ms=8,label=names[t])
        for x,v in zip(C,y):
            a.annotate('%.1f'%v if v>=10 else '%.2f'%v if v<10 and 'tpot' in key else '%.0f'%v,
                       (x,v),textcoords='offset points',xytext=(0,7),fontsize=8,ha='center',color=colors[t])
    if reqline:
        a.axhline(reqline,color='red',ls='--',lw=1.3)
        a.text(C[0],reqline,reqlabel,color='red',fontproperties=fp,fontsize=10,va='bottom')
    a.set_title(title,fontproperties=fp,fontsize=13,fontweight='bold')
    a.set_xlabel('并发数 (concurrency)',fontproperties=fp,fontsize=11)
    a.set_ylabel(ylabel,fontproperties=fp,fontsize=11)
    a.set_xscale('log',base=2); a.set_xticks(C); a.set_xticklabels(C)
    a.legend(prop=fp,fontsize=11); a.grid(alpha=0.3)

line(ax[0,0],'median_tpot_ms','TPOT P50（每 token 延迟）越低越好','ms',4.5,'需求线 4.5ms')
line(ax[0,1],'median_ttft_ms','TTFT P50（首 token 延迟）越低越好','ms',1700,'需求线 1.7s')
line(ax[1,0],'median_e2e_latency_ms','E2E P50（端到端延迟）越低越好','ms')
line(ax[1,1],'output_throughput','输出吞吐（Output Throughput）越高越好','tokens/s')

plt.tight_layout(rect=[0,0,1,0.96])
out='/home/ubuntu/.openclaw/workspace/b300_sweep40k_3way.png'
plt.savefig(out,dpi=130,bbox_inches='tight')
print('saved',out)
EOF=0
