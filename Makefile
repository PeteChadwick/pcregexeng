regexeng	:	regexeng.d test.d
			dmd regexeng.d test.d -unittest -release -O -inline -D -map

clean		:
			rm *.exe *.obj *.map
