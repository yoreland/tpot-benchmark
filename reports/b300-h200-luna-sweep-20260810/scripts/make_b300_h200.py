import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm

fp = fm.FontProperties(fname='/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc')
plt.rcParams['axes.unicode_minus'] = False

C=[1,4,8,16,32]
# B300 tp8 (from S3 sweep, verified 40K/1500)
b300={'tpot':[3.45,4.04,4.92,8.73,16.66],
      'ttft':[245,256,274,696,1123],
      'e2e':[5421.8,6381.9,7748.0,14141.7,26571.5],
      'thru':[272.5,916.8,1356.8,1723.1,1754.1]}
# H200 tp8 (this run)
h200={'tpot':[3.15,5.04,7.86,18.36,34.32],
      'ttft':[1472,1472,1377,1782,2523],
      'e2e':[6138,8858,12072,30122,54242],
      'thru':[244,660,911,789,869]}

col={'B300':'#C44E52','H200':'#4C72B0'}
mk={'B300':'o','H200':'s'}

fig, ax = plt.subplots(2,2, figsize=(15,11))
fig.suptitle('B300 vs H200（均为 tp=8 单机 +EAGLE）· DeepSeek-V4-Flash · 40K in / 1.5K out',
             fontproperties=fp, fontsize=16, fontweight='bold')

def line(a,key,title,ylabel,reqline=None,reqlabel=None,fmt='%.0f'):
    for name,d in [('B300',b300),('H200',h200)]:
        y=d[key]
        a.plot(C,y,marker=mk[name],color=col[name],lw=2.2,ms=8,label=name)
        for x,v in zip(C,y):
            lab = ('%.2f'%v if key=='tpot' else '%.0f'%v)
            a.annotate(lab,(x,v),textcoords='offset points',xytext=(0,7),
                       fontsize=8,ha='center',color=col[name])
    if reqline:
        a.axhline(reqline,color='red',ls='--',lw=1.3)
        a.text(C[0],reqline,reqlabel,color='red',fontproperties=fp,fontsize=10,va='bottom')
    a.set_title(title,fontproperties=fp,fontsize=13,fontweight='bold')
    a.set_xlabel('并发数 (concurrency)',fontproperties=fp,fontsize=11)
    a.set_ylabel(ylabel,fontproperties=fp,fontsize=11)
    a.set_xscale('log',base=2); a.set_xticks(C); a.set_xticklabels(C)
    a.legend(prop=fp,fontsize=12); a.grid(alpha=0.3)

line(ax[0,0],'tpot','TPOT P50（每 token 延迟）越低越好','ms',4.5,'需求线 4.5ms')
line(ax[0,1],'ttft','TTFT P50（首 token 延迟）越低越好','ms',1700,'需求线 1.7s')
line(ax[1,0],'e2e','E2E P50（端到端延迟）越低越好','ms')
line(ax[1,1],'thru','输出吞吐（Output Throughput）越高越好','tokens/s')

plt.tight_layout(rect=[0,0,1,0.96])
out='/home/ubuntu/.openclaw/workspace/b300_vs_h200_tp8.png'
plt.savefig(out,dpi=130,bbox_inches='tight')
print('saved',out)
