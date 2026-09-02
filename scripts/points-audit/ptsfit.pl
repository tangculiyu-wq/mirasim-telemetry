use strict; use JSON::PP; use POSIX qw(strftime mktime);
my $home=$ENV{HOME}; my $uid=$ARGV[0] or die "用法: perl -e <userId>  (Mirasim 流水里的 userId,如 usr_xxx)\n";
my %budget=("7d"=>560000,"7d_fable"=>296800,"5h"=>156800);
sub iso2t { my($s)=@_; my($Y,$M,$D,$h,$m,$sec)=$s=~/(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/; $ENV{TZ}="UTC"; return mktime($sec,$m,$h,$D,$M-1,$Y-1900) }
# 1) 样本:按窗口的 (t, pts) 序列
my $js=JSON::PP->new; local $/; open my $fh,"<","$home/Library/Application Support/EduHuan/samples.json" or die; my $arr=$js->decode(<$fh>); close $fh;
my %ser; for my $s (@$arr){ next unless $s->{user} eq $uid; my $w=$s->{window}; push @{$ser{$w}}, [iso2t($s->{at}), $s->{percent}/100*$budget{$w}] }
for(values %ser){ @$_=sort{$a->[0]<=>$b->[0]}@$_ }
sub ptsAt { my($w,$t)=@_; my $best; for my $p (@{$ser{$w}}){ my $d=abs($p->[0]-$t); $best=[$d,$p->[1]] if !$best || $d<$best->[0] } return ($best && $best->[0]<=150) ? $best->[1] : undef }
# 2) 流水:分类计价
my %rate=( "claude-fable-5-1"=>[10,50,0.25,12.5], "claude-fable-5"=>[10,50,1,12.5], "claude-opus-5"=>[5,25,0.5,6.25], "claude-opus-4-8"=>[5,25,0.5,6.25], "claude-sonnet-5"=>[2,10,0.2,2.5] );
sub usd { my($r,$o)=@_; return ($o->{input}*$r->[0]+$o->{output}*$r->[1]+$o->{cacheRead}*$r->[2]+$o->{cacheWrite}*$r->[3])/1e6 }
my (%H); # 小时桶: h => {f5,f51,f5as51,nonf,other, tok_f, tok_n, n_f5,n_f51,n_nonf}
open $fh,"<","$home/.mirasim/insights/usage-2026-09.ndjson" or die; local $/="\n";
while(my $l=<$fh>){ next unless $l=~/"leg":"relay"/ && $l=~/"status":200/ && $l=~/"userId":"$uid"/; my $o=eval{$js->decode($l)} or next; my $t=iso2t($o->{ts}); my $h=int($t/3600)*3600; my $m=$o->{model}; my $tok=($o->{input}//0)+($o->{output}//0)+($o->{cacheRead}//0)+($o->{cacheWrite}//0);
  if($m eq "claude-fable-5"){ $H{$h}{f5}+=usd($rate{$m},$o); $H{$h}{f5as51}+=usd($rate{"claude-fable-5-1"},$o); $H{$h}{tok_f}+=$tok; $H{$h}{n_f5}++ }
  elsif($m eq "claude-fable-5-1"){ $H{$h}{f51}+=usd($rate{$m},$o); $H{$h}{f5as51}+=usd($rate{$m},$o); $H{$h}{tok_f}+=$tok; $H{$h}{n_f51}++ }
  elsif($m=~/^claude-/){ $H{$h}{nonf}+=usd($rate{$m}//[5,25,0.5,6.25],$o); $H{$h}{tok_n}+=$tok; $H{$h}{n_nonf}++ }
  else { $H{$h}{other}+=($o->{input}*2+$o->{output}*12+$o->{cacheRead}*0.2)/1e6 } }
close $fh;
# 3) 逐小时表 (CST) 从样本起点到终点
my ($t0,$t1)=($ser{"7d"}[0][0], $ser{"7d"}[-1][0]); my $hs=int($t0/3600+1)*3600; my $he=int($t1/3600)*3600;
$ENV{TZ}="Asia/Shanghai";
printf "%-11s %8s %8s | %7s %7s %7s | %7s %6s | %s\n","CST小时","Δ7d点","ΔFable点","F5\$","F5.1\$","非F\$","其他\$","次数","备注";
my (%agg);
for(my $h=$hs;$h<$he;$h+=3600){ my $a7=ptsAt("7d",$h); my $b7=ptsAt("7d",$h+3600); my $af=ptsAt("7d_fable",$h); my $bf=ptsAt("7d_fable",$h+3600); next unless defined $a7 && defined $b7 && defined $af && defined $bf; my $d7=$b7-$a7; my $df=$bf-$af; my $r=$H{$h}||{};
  my $note=""; my $f5=$r->{f5}//0; my $f51=$r->{f51}//0; my $nf=$r->{nonf}//0;
  if($f5>1 && $f51<0.5 && $nf<0.5){ $note="纯F5"; $agg{f5}{usd}+=$f5; $agg{f5}{pts}+=$df; $agg{f5}{pts7}+=$d7; $agg{f5}{tok}+=$r->{tok_f} }
  if($f51>1 && $f5<0.5){ $note="F5.1".($nf>0.5?"+非F":""); $agg{f51}{usd}+=$f51; $agg{f51}{pts}+=$df; $agg{f51}{tok}+=$r->{tok_f} }
  if($nf>1 && $f5+$f51<0.5){ $note="纯非F"; $agg{nf}{usd}+=$nf; $agg{nf}{pts}+=$d7-$df; $agg{nf}{ptsf}+=$df; $agg{nf}{tok}+=$r->{tok_n} }
  $agg{all}{d7}+=$d7; $agg{all}{df}+=$df; $agg{all}{f5}+=$f5; $agg{all}{f51}+=$f51; $agg{all}{nf}+=$nf; $agg{all}{f5as51}+=$r->{f5as51}//0;
  printf "%-11s %8.0f %8.0f | %7.1f %7.1f %7.1f | %7.1f %6d | %s\n", strftime("%m-%d %H",localtime($h)), $d7,$df,$f5,$f51,$nf,$r->{other}//0,($r->{n_f5}//0)+($r->{n_f51}//0)+($r->{n_nonf}//0),$note }
print "\n=== 纯净时段推算 ===\n";
if($agg{f5}{pts}){ printf "纯 Fable5 时段: \$%.0f ↔ Fable窗 %.0f 点(7d窗 %.0f 点) → %.5f \$/点, %.0f 点/百万token; 7d/Fable 点比 %.3f\n",$agg{f5}{usd},$agg{f5}{pts},$agg{f5}{pts7},$agg{f5}{usd}/$agg{f5}{pts},$agg{f5}{pts}/$agg{f5}{tok}*1e6,$agg{f5}{pts7}/$agg{f5}{pts} }
if($agg{f51}{pts}){ printf "Fable5.1 时段:  \$%.0f ↔ Fable窗 %.0f 点 → %.5f \$/点, %.0f 点/百万token\n",$agg{f51}{usd},$agg{f51}{pts},$agg{f51}{usd}/$agg{f51}{pts},$agg{f51}{pts}/$agg{f51}{tok}*1e6 }
if($agg{nf}{pts}){ printf "纯非Fable 时段: \$%.0f ↔ 7d窗 %.0f 点(其间 Fable窗动了 %.0f 点) → %.5f \$/点, %.0f 点/百万token\n",$agg{nf}{usd},$agg{nf}{pts},$agg{nf}{ptsf},$agg{nf}{usd}/$agg{nf}{pts},$agg{nf}{pts}/$agg{nf}{tok}*1e6 }
printf "\n全时段合计: Δ7d %.0f 点, ΔFable %.0f 点; F5 \$%.0f (按5.1价 \$%.0f), F5.1 \$%.0f, 非F \$%.0f\n",$agg{all}{d7},$agg{all}{df},$agg{all}{f5},$agg{all}{f5as51}-$agg{all}{f51},$agg{all}{f51},$agg{all}{nf};
printf "整体 Fable \$/点(实价) %.5f, (全按5.1价) %.5f; 非Fable \$/点 %.5f\n",($agg{all}{f5}+$agg{all}{f51})/$agg{all}{df},$agg{all}{f5as51}/$agg{all}{df},$agg{all}{nf}/($agg{all}{d7}-$agg{all}{df}) if $agg{all}{df};
