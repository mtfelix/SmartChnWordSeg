######################################################
### Yet another chn word seg tool.
### 注意：所有输入输出文件的编码都必须是UTF8的。
###
###  Revision History: 
###  2012.3.15 使用trie结构存储词频表，加速查询(to do ....)
###  2012.3.14 增加了前后缀最长长度记录以减少无谓词频表查询，加快速度,特别是对于长句子
###                    来说，极大地加快了iniArcTable的速度。
###  2012.3.13 Created by Hongfei Jiang
###
######################################################
#!

use strict;
use open ":encoding(utf8)",":std";

# 全局变量
$main::dictFileName = "";
%main::wordFreqList = (); 
%main::longestWordListStart = ();  # 存储前缀对应最长词条长度，以限制扫描长度。
%main::longestWordListEnd = ();  # 存储后缀对应最长词条长度，以限制扫描长度。

@main::arcTable = ();

@main::wordArray = ();
$main::lengthOfChnLine = 0; 

@main::left2RightSegLabel=(); # 存储分割标记
@main::right2LeftSegLabel=();
$main::left2RightSegFreqProduct = 0;#存储路径得分
$main::right2LeftSegFreqProduct = 0;


if($ARGV[0] eq "-help"){
	print STDERR "\n-----------------------------------------------------------------------";
	print STDERR "\nUsage:";
	print STDERR "\n\tperl $0 [freqFile] < srcMandarinFile > segmentedFile";
	print STDERR "\n-----------------------------------------------------------------------\n";

	exit;
}
my $dictFileName = "";
if($ARGV[0] eq ""){
	print STDERR "\nUsing default frequency dictionary\n";
	$main::dictFileName="Mandarin.fre.complete";
}
else{
	$main::dictFileName=$ARGV[0];
}

#reading the dictionary
#print STDERR "Reading dictionary $dictFileName\n";
open (dictFile, $main::dictFileName) or die "can not open $main::dictFileName\n";

#for debug
#print STDERR "dic load start\n",`date`,"\n";


while(<dictFile>){
	chomp();
	my ($thisFreq,$thisChnWord) = split(/\t/,$_);
	#for debug
	#print STDERR "$thisFreq $thisChnWord \n";
	$main::wordFreqList{$thisChnWord}=$thisFreq;
	
	my @tempArray = split(//,$thisChnWord);
	my $thisLen = @tempArray;
	
	# 记录前缀最长长度
	if(exists $main::longestWordListStart{$tempArray[0]}){
		   $main::longestWordListStart{$tempArray[0]} = $thisLen if ($thisLen > $main::longestWordListStart{$tempArray[0]});
	}else{
		   $main::longestWordListStart{$tempArray[0]} = $thisLen;
	}
	
	# 记录后缀最长长度
	if(exists $main::longestWordListEnd{$tempArray[$thisLen-1]}){
		   $main::longestWordListEnd{$tempArray[$thisLen-1]} = $thisLen if ($thisLen > $main::longestWordListEnd{$tempArray[$thisLen-1]});
	}else{
		   $main::longestWordListEnd{$tempArray[$thisLen-1]} = $thisLen;
	}
}
close(dictFile);

#for debug
#print STDERR "dic load end\n",`date`,"\n";

#segmenting
my $totalCount = 0;
my $failCount = 0;
my $count = 0;
my $is_seg_ok = "yes"; 
while(<STDIN>){
	chomp();
	$count++;
	my $thisLine = $_;
	my $thisSegResult = "";
	#for debug
	#my $len = length($thisLine)/2;
    #print STDERR "\n The sent $count is around $len Chinese char\n";
	$thisSegResult = segmentSentence($thisLine);
	print "$thisSegResult\n";
}

#
sub segmentSentence{
	
	my ($chnLine) = @_;
	@main::wordArray = ();
	@main::wordArray = split(//,$chnLine);
	
	#for debug
	#print STDERR join("\n",@main::wordArray);
	
	$main::lengthOfChnLine = 0;
	$main::lengthOfChnLine = @main::wordArray; ## 单字个数
	
	#for debug
    #print STDERR "iniArcTable load start\n",`date`,"\n";
	
	#---------------------------------------------------------------------------
	#step1: 初始化main::arcTable
	iniArcTable();
	
	#for debug
    #print STDERR "iniArcTable load end\n",`date`,"\n";
	
		#for debug
    #print STDERR "biDirectionSegPathSearch load start\n",`date`,"\n";
	
	#---------------------------------------------------------------------------
	#step2: 双向搜索分词路径
	biDirectionSegPathSearch();
	
	#for debug
    #print STDERR "biDirectionSegPathSearch load end\n",`date`,"\n";
		
	#---------------------------------------------------------------------------
	#step3: 获取最优分词路径(词频乘积最大的路径)
	my $chnSegResult = getBestSegResult();
	
	return $chnSegResult;
	
    ##return ("fail",$chnSegResult); ## default as fail

}

sub iniArcTable{
	
	####初始化main::arcTable
	# 1. 对于单字，如果在词频表中有赋值为对应词频，否则为1(如果词频表中没有的单字，默认词频为小于1的正数，是不是就倾向于把它们捏在一块输出？存疑)
	# 2.对于二个以上的字串，如果词频表中有赋值为对应词频，否则为-1
	#  
	#  速度瓶颈所在：
	# 经过分析测试，发现这个函数是此分词算法中time cost最大的，因为这个是o(n^2)，而后面的search部分可以jump
	# 所以，对于长句子来说，这个地方的提速是关键的。
	# 在对一个输入汉字个数为2300+的句子的分词测试中，
	# 没有优化的 iniArcTable花费6分钟，biDirectionSegPathSearch花费1秒
	# 2012.3.14优化后的版本， iniArcTable花费2秒，biDirectionSegPathSearch花费1秒
	# 不过，对于短句子，提速并不明显。
	##################
	
	@main::arcTable = ();
	
	for(my $i=0;$i<$main::lengthOfChnLine;$i++){
		 my $possibleMaxLen = 0;
		 
		  if (exists $main::longestWordListStart{$main::wordArray[$i]}){
		       $possibleMaxLen = $main::longestWordListStart{$main::wordArray[$i]};
		  }
		 for(my $j=$i;$j<$main::lengthOfChnLine;$j++){
		 	   if($j==$i){ ## 单字处理
		 	   	     my $singleChar = $main::wordArray[$i];
		 	   	      if(defined $main::wordFreqList{$singleChar}){
		 	   	      	   $main::arcTable[$i][$j] = $main::wordFreqList{$singleChar};
		 	   	      }else{
		 	   	            $main::arcTable[$i][$j] = 1;
		 	   	      }
		 	   }else{ ## 多字串处理
		 	   	       if($j<($i+$possibleMaxLen+1)){# 可能在词表中出现
		 	   	       	     my $currentStr = join("",@main::wordArray[$i..$j]);
		 	   	              if(defined $main::wordFreqList{$currentStr}){
		 	   	      	              $main::arcTable[$i][$j] = $main::wordFreqList{$currentStr};
		 	   	              }else{
		 	   	                       $main::arcTable[$i][$j] = -1;
		 	   	              }
		 	   	       }else{ # 不可能在词表中出现的词串，其arcTable值赋值为-1, 不用去检验$main::wordFreqList{$currentStr}存在与否
		 	   	              $main::arcTable[$i][$j] = -1;
		 	   	       }
		 	   	       
		 	   }
		 }##end_for_j
	}##end_for_i
	
}

#for debug
sub check_arcTable{
	 	
	for(my $i=0; $i<$main::lengthOfChnLine;$i++){
		for(my $j=$i;$j<$main::lengthOfChnLine;$j++){
			if(0 ==  $main::arcTable[$i][$j]){
				   my $str = join("",@main::wordArray[$i..$j]);
			       # print STDERR "\n($str)arcTable[$i][$j]:0\n";
			        exit;
			}				
		}
	}
}

sub biDirectionSegPathSearch{
	  
	  @main::left2RightSegLabel=(); # 存储分割标记
      @main::right2LeftSegLabel=();
      $main::left2RightSegFreqProduct = 0;#存储路径得分
      $main::right2LeftSegFreqProduct = 0;
      
      for(my $k=0;$k<$main::lengthOfChnLine;$k++){
		   $main::left2RightSegLabel[$k]=0;
		   $main::left2RightSegLabel[$k]=0;
	}
      
      left2RightSegPathSearch();
      right2LeftSegPathSearch();    
}

sub left2RightSegPathSearch{
	 
	 $main::left2RightSegFreqProduct = 0;
	 
	 my $currentCharIndex = 0; ##当前字index
	 my $RealCharIndexEnd = $main::lengthOfChnLine - 1;
	 
	 my $found = 0; 
	 
	 while($currentCharIndex<$main::lengthOfChnLine){
	 	
		   my  $currentCharIndexEnd  =  $RealCharIndexEnd; ## default 右边界是词串尾
		   
		   ## 优化右边界$currentCharIndexEnd, 避免每次都从句尾逐一往回扫描。
		   if (exists $main::longestWordListStart{$main::wordArray[$currentCharIndex]}){
		          my $possibleMaxEndIndex = $currentCharIndex + $main::longestWordListStart{$main::wordArray[$currentCharIndex]} - 1; ## 从首词词缀最长串hash来看的可能最长值。
		          if($RealCharIndexEnd<$possibleMaxEndIndex){ ## 不能超出实际词串的长度
		          	     $currentCharIndexEnd = $RealCharIndexEnd;
		          }else{
		          	      $currentCharIndexEnd = $possibleMaxEndIndex;
		          }
		   }else{## 如果$main::longestWordListStart{$main::wordArray[$currentCharIndexEnd]}不存在，当单字处理
		          $currentCharIndexEnd = $currentCharIndex;
		   }

		   $found=0;
	    
	       while((!$found)&&($currentCharIndexEnd>=$currentCharIndex)){
	       	      if($main::arcTable[$currentCharIndex][$currentCharIndexEnd]!=-1){
				          $main::left2RightSegFreqProduct+=log($main::arcTable[$currentCharIndex][$currentCharIndexEnd]);
				          $found=1;
			      }
			      else{
				          $currentCharIndexEnd--;
			      }
	       	     
	       }##end_of_while((!$found)...
	       
	       $main::left2RightSegLabel[$currentCharIndexEnd]=1;
		   $currentCharIndex=$currentCharIndexEnd+1;
	       
	 }## end_of_while($currentCharIndex<....
	 
}

## 从右到左加速起来不是很方便吧？？看看原来版本如何考虑的
## 可以同样设置一个%main::longestWordListEnd这样的结构来加速。
sub right2LeftSegPathSearch{
	  $main::right2LeftSegFreqProduct = 0;
	  
	  my $currentCharIndex = $main::lengthOfChnLine - 1;
	  
	  while($currentCharIndex>=0){
	  	
	  	     my $currentStartCharIndex = 0; ## 默认从0开始扫描
	  	     
	  	     #  优化左边界$currentStartCharIndex, 尽可能避免无谓查询
	  	     if(exists $main::longestWordListEnd{$main::wordArray[$currentCharIndex]}){ ## longestWordListEnd中如果有，考虑优化之
	  	             my $possibleMaxStrLen = $main::longestWordListEnd{$main::wordArray[$currentCharIndex]};
	  	             my $possibleStartIndex = $currentCharIndex - $possibleMaxStrLen + 1;
	  	             $currentStartCharIndex = $possibleStartIndex if ($possibleStartIndex>0); ## 优化后，从可能的位置开始扫，可以避免从0开始扫描的无谓操作
                      $currentStartCharIndex = $currentCharIndex if ($currentStartCharIndex > $currentCharIndex); 
	  	     }else{## longestWordListEnd中如果没有，单字处理
	  	     	    $currentStartCharIndex = $currentCharIndex;
	  	     }
	  	       	     
	  	     my $found = 0;
	  	     
	  	     while( (!$found) && ($currentStartCharIndex<=$currentCharIndex)){
	  	     	    if($main::arcTable[$currentStartCharIndex][$currentCharIndex]!=-1){
	  	     	    	        
				            $main::right2LeftSegFreqProduct+=log($main::arcTable[$currentStartCharIndex][$currentCharIndex]);
				            $found=1;
			         }else{
			         	   $currentStartCharIndex++;
	  	     	    	}
	  	               
	  	     }##end_of_while( (!$found) &&....
	  	     
	  	     $main::right2LeftSegLabel[$currentStartCharIndex] = 1;
	  	     $currentCharIndex = $currentStartCharIndex-1;
	  	     
	  }##end_of_while($currentCharIndex>=0){
}

sub getBestSegResult{
	
	  my $finalSegResult = "";
       if($main::left2RightSegFreqProduct > $main::right2LeftSegFreqProduct ){ 

              for(my $i=0;$i<$main::lengthOfChnLine;$i++){
                    $finalSegResult = $finalSegResult.$main::wordArray[$i];
                    $finalSegResult = $finalSegResult." " if(1 == $main::left2RightSegLabel[$i]);
              }
       }else{

              for(my $j=0;$j<$main::lengthOfChnLine;$j++){
                    $finalSegResult = $finalSegResult." " if(1 == $main::right2LeftSegLabel[$j]);
                    $finalSegResult = $finalSegResult.$main::wordArray[$j];
              }
       }
       
       $finalSegResult =~s/^ +//;
       $finalSegResult =~s/ +$//;
       
       return $finalSegResult;
}