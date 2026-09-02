use strict; use JSON::PP; use POSIX qw(strftime mktime);
my $home=$ENV{HOME}; my $uid=$ARGV[0] or die "用法: perl -e <userId>  (Mirasim 流水里的 userId,如 usr_xxx)\n";
my %budget=("7d"=>560000,"7d_fable"=>296800);
sub iso2t { my($s)=@_; my($Y,$M,$D,$h,$m,$sec)=$s=~/(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/; $ENV{TZ}="UTC"; return mktime($sec,$m,$h,$D,$M-1,$Y-1900) }
my $js=JSON::PP->new; local $/; open my $fh,"<","$home/Library/Application Support/EduHuan/samples.json" or die; my $arr=$js->decode(<$fh>); close $fh;
my %ser; for my $s (@$arr){ next unless $s->{user} eq $uid; my $w=$s->{window}; next unless $budget{$w}; push @{$ser{$w}}, [iso2t($s->{at}), $s->{percent}/100*$budget{$w}] }
for(values %ser){ @$_=sort{$a->[0]<=>$b->[0]}@$_ }
sub ptsAt { my($w,$t)=@_; my $best; for my $p (@{$ser{$w}}){ my $d=abs($p->[0]-$t); $best=[$d,$p->[1]] if !$best || $d<$best->[0] } return ($best && $best->[0]<=150) ? $best->[1] : undef }
my %R=( f51=>[10,50,0.25,12.5], f5=>[10,50,1,12.5], opus=>[5,25,0.5,6.25], sonnet=>[2,10,0.2,2.5] );
sub usd { my($r,$o)=@_; return ($o->{input}*$r->[0]+$o->{output}*$r->[1]+$o->{cacheRead}*$r->[2]+$o->{cacheWrite}*$r->[3])/1e6 }
my %H; open $fh,"<","$home/.mirasim/insights/usage-2026-09.ndjson" or die; local $/="\n";
while(my $l=<$fh>){ next unless $l=~/"leg":"relay"/ && $l=~/"status":200/ && $l=~/"userId":"$uid"/; my $o=eval{$js->decode($l)} or next; my $t=iso2t($o->{ts}); my $h=int($t/3600)*3600; my $m=$o->{model};
  my $cls = $m eq "claude-fable-5" ? "f5" : $m eq "claude-fable-5-1" ? "f51" : $m=~/^claude-opus/ ? "opus" : $m=~/^claude-sonnet/ ? "sonnet" : "other"; next if $cls eq "other";
  my $b=$H{$h}{$cls}||={}; $b->{n}++; $b->{$_}+=($o->{$_}//0) for qw(input output cacheRead cacheWrite);
  $b->{usd_own}+=usd($R{$cls},$o); $b->{usd_f5}+=usd($R{f5},$o); $b->{usd_f51}+=usd($R{f51},$o); $b->{usd_opus}+=usd($R{opus},$o) }
close $fh;
my ($t0,$t1)=($ser{"7d"}[0][0], $ser{"7d"}[-1][0]); my $hs=int($t0/3600+1)*3600; my $he=int($t1/3600)*3600; $ENV{TZ}="Asia/Shanghai";
print "纯净小时: 点增量 与 该小时 token 构成(百万) / 按不同价目算的美元\n";
printf "%-9s %-5s %8s | %6s %6s %6s %6s | %7s %7s %7s | %6s %6s %6s\n","小时","模型","点","入","出","缓读","缓写","按F5\$","按5.1\$","按Opus\$","点/F5\$","点/5.1\$","点/Op\$";
my %agg;
for(my $h=$hs;$h<$he;$h+=3600){ my $a7=ptsAt("7d",$h); my $b7=ptsAt("7d",$h+3600); my $af=ptsAt("7d_fable",$h); my $bf=ptsAt("7d_fable",$h+3600); next unless defined $a7 && defined $b7 && defined $af && defined $bf;
  my $d7=$b7-$a7; my $df=$bf-$af; my $r=$H{$h}||{}; my @cls=grep { ($r->{$_}{usd_own}//0) > 0.5 } keys %$r; next unless @cls==1; my $c=$cls[0]; my $b=$r->{$c};
  my $pts = ($c=~/^f/) ? $df : $d7-$df; next if $pts < 500;
  printf "%-9s %-5s %8.0f | %6.2f %6.2f %6.2f %6.2f | %7.1f %7.1f %7.1f | %6.0f %6.0f %6.0f\n", strftime("%d日%H时",localtime($h)), $c, $pts, $b->{input}/1e6,$b->{output}/1e6,$b->{cacheRead}/1e6,$b->{cacheWrite}/1e6, $b->{usd_f5},$b->{usd_f51},$b->{usd_opus}, $pts/$b->{usd_f5}, $pts/$b->{usd_f51}, $pts/$b->{usd_opus};
  $agg{$c}{pts}+=$pts; $agg{$c}{$_}+=$b->{$_} for qw(input output cacheRead cacheWrite usd_f5 usd_f51 usd_opus usd_own) }
print "\n=== 汇总:每类模型的点 ÷ 各价目美元(若两类 Fable 在同一列上数值相同,说明点是按同一套权重扣的) ===\n";
for my $c (sort keys %agg){ my $a=$agg{$c}; my $tok=($a->{input}+$a->{output}+$a->{cacheRead}+$a->{cacheWrite})/1e6;
  printf "%-6s 点 %8.0f | token %6.2fM (缓读占 %2.0f%%, 缓写占 %2.0f%%, 出 %4.1f%%) | 点/F5\$ %5.0f  点/5.1\$ %5.0f  点/Opus\$ %5.0f | 点/百万token %4.0f\n", $c, $a->{pts}, $tok, $a->{cacheRead}/$tok/1e6*100, $a->{cacheWrite}/$tok/1e6*100, $a->{output}/$tok/1e6*100, $a->{pts}/$a->{usd_f5}, $a->{pts}/$a->{usd_f51}, $a->{pts}/$a->{usd_opus}, $a->{pts}/$tok }
# 拟合:Fable 两代共用一套 token 权重 (入,出,缓读,缓写) 能不能同时解释 F5 与 F5.1 的点?
# 假设点 = k × (入×1 + 出×5 + 缓读×w_r + 缓写×1.25) 即价目比例,只让缓读权重 w_r 与 k 浮动, 分别对 F5、F5.1 求最优
print "\n=== 用价目比例(入1:出5:缓写1.25)拟合缓读权重 w_r 与倍率 k ===\n";
for my $c ("f5","f51","opus"){ my $a=$agg{$c}; next unless $a; my $best;
  for(my $wr=0.02;$wr<=0.3;$wr+=0.005){ my $base=($a->{input}*1+$a->{output}*5+$a->{cacheRead}*$wr+$a->{cacheWrite}*1.25)/1e6; my $k=$a->{pts}/$base; push @{$best}, [$wr,$k] }
  # 无法只用汇总解;打印几个候选 w_r 对应的 k,供比较两代是否能取同一组 (w_r,k)
  printf "%-5s ", $c; for my $wr (0.025,0.05,0.1){ my $base=($a->{input}*1+$a->{output}*5+$a->{cacheRead}*$wr+$a->{cacheWrite}*1.25)/1e6; printf "w_r=%.3f→k=%5.1f  ", $wr, $a->{pts}/$base } print "\n" }
