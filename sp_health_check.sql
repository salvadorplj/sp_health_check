/*
███████╗██████╗    ██╗  ██╗███████╗ █████╗ ██╗  ████████╗██╗  ██╗         ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
██╔════╝██╔══██╗   ██║  ██║██╔════╝██╔══██╗██║  ╚══██╔══╝██║  ██║        ██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
███████╗██████╔╝   ███████║█████╗  ███████║██║     ██║   ███████║        ██║     ███████║█████╗  ██║     █████╔╝ 
╚════██║██╔═══╝    ██╔══██║██╔══╝  ██╔══██║██║     ██║   ██╔══██║        ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗ 
███████║██║███████╗██║  ██║███████╗██║  ██║███████╗██║   ██║  ██║███████╗╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
╚══════╝╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝
https://sqlhealthcheck.net
                                                                                                                 
This script was put together by Salvador Lancaster
@sqlslancaster - http://twitter.com/sqlslancaster

--===============================================================================================================================--
--======================================================= LICENSE ===============================================================--
--===============================================================================================================================--

sp_health_check is licensed free as long as all its contents are preserved, including this header. The script and all its contents
cannot be redistributed or sold either partially or as a whole without the author's expressed written approval. 

Some scripts that are part of this compound of code were not created by the author and belong to their original creators or owners 
for all purposes. Other authors' credit is specified within the stored procedure's code. You can find more details on this at 
https://sqlhealthcheck.net/overview

This script is provided as is without guarantee, documentation, or technical support, and should be properly understood and tested
before being deployed in a production enviroment.

--===============================================================================================================================--
--======================================================= HOW TO ================================================================--
--===============================================================================================================================--

[!] When using for the first time, execute the uncommented code to create the stored procedure, and then use the line below for all
    subsequent executions:
    
    EXEC [dbo].[sp_health_check]; -- run against the database it was stored at, [master] unless it was changed
*/

USE [master]; -- [!] Change if you have a DBA-specific database and you want to save this stored procedure in it
GO
IF OBJECT_ID('[dbo].[sp_health_check]') IS NOT NULL BEGIN DROP PROCEDURE [dbo].[sp_health_check]; END;
GO
CREATE PROCEDURE [dbo].[sp_health_check]
AS

SET NOCOUNT ON;

IF (SELECT  [c].[value] FROM [sys].[configurations] [c] WHERE [c].[name]=N'xp_cmdshell')<>1
BEGIN 
	RAISERROR('[sp_health_check] requires [xp_cmdshell] to be enabled',10,1);
	RETURN;
END;

IF (IS_SRVROLEMEMBER ( 'sysadmin', SUSER_NAME() ))<>1
BEGIN
    RAISERROR('[sp_health_check] must execute under sysadmin priviledges',10,1);
	RETURN;
END;

	DECLARE @cmd NVARCHAR(MAX);


--===============================================================================================================================--
--================================================ Performance Baselines Values =================================================--
--===============================================================================================================================--
	
	/*  PENDING ITEMS:
	    - Measure IO latency
	    - Capture waits
	*/

	-- ### dm_os_performance_counters
	DECLARE @os_performance_counters INT; SELECT @os_performance_counters=COUNT(*) FROM [sys].[dm_os_performance_counters];

	IF @os_performance_counters>0
	BEGIN

		-- ### General perfmon values	
		IF OBJECT_ID('tempdb..#perfmon_baseline') IS NOT NULL BEGIN DROP TABLE [#perfmon_baseline]; END;
		DECLARE @start_time DATETIME=GETDATE();

		SELECT [counter_name], [cntr_value]
		INTO [#perfmon_baseline]
		FROM [sys].[dm_os_performance_counters]
		WHERE ([counter_name] IN  
							('Batch Requests/sec'			,'Logins/sec'				,'Logouts/sec'				,'Connection Reset/sec'
							,'SQL Compilations/sec'			,'SQL Re-Compilations/sec'	,'Query optimizations/sec'
							,'Page writes/sec'				,'Page Splits/sec'			,'Page reads/sec'			,'Checkpoint pages/sec'			
							,'Lazy writes/sec'				,'Forwarded Records/sec'	,'Page Deallocations/sec'	,'Pages Allocated/sec'
							,'Readahead pages/sec'			,'Full Scans/sec'			,'Index Searches/sec'		,'Page lookups/sec'
							,'Range Scans/sec'				,'Pages compressed/sec'
							)
			AND [instance_name]<>'internal'
		)
		OR ([counter_name] IN 
							('Transactions/sec'					,'Write Transactions/sec'			,'Number of Deadlocks/sec'
							,'Lock Requests/sec'				,'Log Bytes Flushed/sec'			,'Log Flushes/sec'
							)
			AND [instance_name]='_Total'
		);

		-- ### Mirroring values
		DECLARE @mirror_COUNT INT; SELECT @mirror_COUNT=COUNT([mirroring_guid]) FROM [sys].[database_mirroring] WHERE  [mirroring_guid] IS NOT NULL;
		DECLARE @mirrorCOUNTsynch INT; SELECT @mirrorCOUNTsynch=COUNT([mirroring_guid]) FROM [sys].[database_mirroring] WHERE [mirroring_state]=4;

		IF @mirror_COUNT>0
		BEGIN
			IF OBJECT_ID('tempdb..#perfmon_baseline_mirroring') IS NOT NULL BEGIN DROP TABLE [#perfmon_baseline_mirroring]; END;

			SELECT	[counter_name]
				   ,[cntr_value]
			INTO	[#perfmon_baseline_mirroring]
			FROM	[sys].[dm_os_performance_counters]
			WHERE	[object_name]='SQLServer:Database Mirroring'
					AND ([counter_name] IN ('Bytes Sent/sec' ,'Bytes Received/sec' ,'Mirrored Write Transactions/sec' ,'Transaction Delay')
						 AND [instance_name]='_Total'
						 );
		END;

		WAITFOR DELAY '00:00:01:30'; -- Timeframe to compare the captured data

		DECLARE  @BatchRequests_sec BIGINT,		@Transactions_sec BIGINT	,@WriteTransactions_sec BIGINT,		@Logins_sec BIGINT				,@Logouts_sec BIGINT
				,@Compilations_sec BIGINT,		@ReCompilations_sec BIGINT	,@QueryOptimizations_sec BIGINT,	@BufferPageWrites_sec BIGINT	,@BufferPageReads_sec BIGINT
				,@BufferLazyWrites_sec BIGINT,	@CheckpointPages_sec BIGINT	,@PageSplits_sec BIGINT;

		;WITH [perfmon_results] AS (
			SELECT * FROM 
			(	SELECT [perfmon_diff].[counter_name], ( CONVERT(DECIMAL(32,2),([perfmon_diff].[cntr_value])-CONVERT(DECIMAL(32,2),[perfmon_baseline].[cntr_value])) / (DATEDIFF(MILLISECOND,@start_time,GETDATE())/1000) ) [cntr_value]
				FROM [sys].[dm_os_performance_counters] [perfmon_diff]
				INNER JOIN [#perfmon_baseline] [perfmon_baseline] ON [perfmon_baseline].[counter_name] = [perfmon_diff].[counter_name]
				WHERE ([perfmon_diff].[counter_name] IN  
							('Batch Requests/sec'			,'Logins/sec'				,'Logouts/sec'				,'Connection Reset/sec'
							,'SQL Compilations/sec'			,'SQL Re-Compilations/sec'	,'Query optimizations/sec'
							,'Page writes/sec'				,'Page Splits/sec'			,'Page reads/sec'			,'Checkpoint pages/sec'			
							,'Lazy writes/sec'				,'Forwarded Records/sec'	,'Page Deallocations/sec'	,'Pages Allocated/sec'
							,'Readahead pages/sec'			,'Full Scans/sec'			,'Index Searches/sec'		,'Page lookups/sec'
							,'Range Scans/sec'				,'Pages compressed/sec'
							)
					AND [instance_name]<>'internal'
				)
				OR ([perfmon_diff].[counter_name] IN 
					('Transactions/sec'				,'Write Transactions/sec'
					,'Lock Requests/sec'			,'Log Bytes Flushed/sec'	,'Log Flushes/sec'
				)
					AND [perfmon_diff].[instance_name]='_Total'
				)
			) [perfmon_results_t]
		)
		SELECT --  @BatchRequests_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Batch Requests/sec'),0)
				@Transactions_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Transactions/sec'),0)
				,@WriteTransactions_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Write Transactions/sec'),0)
				,@Logins_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Logins/sec'),0)
				,@Logouts_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Logouts/sec'),0)
				,@Compilations_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='SQL Compilations/sec'),0)
				,@ReCompilations_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='SQL Re-Compilations/sec'),0)
				,@QueryOptimizations_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Query optimizations/sec'),0)
				,@BufferPageWrites_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Page writes/sec'),0)
				,@BufferPageReads_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Page reads/sec'),0)
				,@BufferLazyWrites_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Lazy writes/sec'),0)
				,@CheckpointPages_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Checkpoint pages/sec'),0)
				,@PageSplits_sec=ISNULL((SELECT [perfmon_results].[cntr_value] FROM [perfmon_results] WHERE [perfmon_results].[counter_name]='Page Splits/sec'),0)
		FROM [perfmon_results];

		IF OBJECT_ID('tempdb..#perfmon_baseline') IS NOT NULL BEGIN DROP TABLE [#perfmon_baseline]; END;
	
	END;


--===============================================================================================================================--
--======================================================= SERVER DETAILS ========================================================--
--===============================================================================================================================--

	-- ### Variables
	DECLARE @ip NVARCHAR(56); SELECT @ip=[dec].[local_net_address] FROM [sys].[dm_exec_connections] AS [dec] WHERE [dec].[session_id] = @@SPID;
	DECLARE @Domain NVARCHAR(128); EXEC [master].[sys].[xp_regread] 'HKEY_LOCAL_MACHINE', 'SYSTEM\\CurrentControlSet\\services\\Tcpip\\Parameters', N'Domain',@Domain OUTPUT; IF @Domain IS NULL SET @Domain='Not set';
	DECLARE @iscluster INT; SELECT @iscluster=CONVERT(INT,SERVERPROPERTY('IsClustered')); 
	DECLARE @tempDBcreate DATETIME; SELECT @tempDBcreate=[create_date] FROM [sys].[databases] WHERE [name]='tempdb';
	DECLARE @engine_minutes DECIMAL, @engine_hours INT; SET @engine_minutes=DATEDIFF(MI,@tempDBcreate,GETDATE()); SET @engine_hours=@engine_minutes/60; SET @engine_minutes=((@engine_minutes/60)-@engine_hours)*60;

	-- ### Print Server and OS info
	DECLARE @OS NVARCHAR(128); SELECT @OS=RIGHT(@@VERSION, LEN(@@VERSION)- 0 -CHARINDEX (' Windows', @@VERSION)); SELECT @OS=LEFT(@OS, LEN(@OS)-0 -CHARINDEX(' (',@OS));
	PRINT 'SQL Server '+CONVERT(NVARCHAR(128), SERVERPROPERTY('ProductVersion'))+' '+CONVERT(NVARCHAR(128),SERVERPROPERTY('Edition'))+' on '+REPLACE(@OS,CHAR(10),'');

	-- ### Instance details
	IF (CONVERT(INT,@@microsoftversion)>=171051460) --SQL2008R2SP1 or greater
	BEGIN
			-- ### Is this a virtual machine?
			SET @cmd = N'SELECT @server_type=CASE WHEN [virtual_machine_type] = 1 THEN ''virtual'' ELSE ''physical'' END FROM sys.dm_os_sys_info';
			DECLARE @server_type NVARCHAR(8); EXEC [master].[sys].[sp_executesql] @cmd, N'@server_type NVARCHAR(8) out', @server_type OUTPUT;
			
			-- ### Is the service clustered?
			IF (@iscluster>0) 
			BEGIN 
				PRINT 'The service "'+CONVERT(NVARCHAR,SERVERPROPERTY('ServerName'))+'" is clustered currently running on host "'+CONVERT(NVARCHAR,SERVERPROPERTY('ComputerNamePhysicalNetBIOS'))+'" since '+CONVERT(NVARCHAR(16),@tempDBcreate,101)+' '+CONVERT(NVARCHAR(16),@tempDBcreate,108)+', '+CONVERT(NVARCHAR(6),@engine_hours)+' hours and '+CONVERT(NVARCHAR(3),@engine_minutes)+' minutes ago as process ID '+CONVERT(NVARCHAR,SERVERPROPERTY('ProcessID'));
			END;
			IF (@iscluster=0) 
			BEGIN 
				PRINT 'The instance "'+CONVERT(NVARCHAR,SERVERPROPERTY('ServerName'))+'" is non-clustered, runs on the '+@server_type+' host "'+CONVERT(NVARCHAR,SERVERPROPERTY('ComputerNamePhysicalNetBIOS'))+'", ip "'+@ip+'", domain "'+@Domain+'"'; 
			END;
	END;
	ELSE --SQL2008R2 or lower
		BEGIN
			-- ### Is the service clustered?
			IF (@iscluster>0) 
			BEGIN 
				PRINT 'The service "'+CONVERT(NVARCHAR,SERVERPROPERTY('ServerName'))+'" is clustered currently running on host "'+CONVERT(NVARCHAR,SERVERPROPERTY('ComputerNamePhysicalNetBIOS'))+'" since '+CONVERT(NVARCHAR(16),@tempDBcreate,101)+' '+CONVERT(NVARCHAR(16),@tempDBcreate,108)+', '+CONVERT(NVARCHAR(6),@engine_hours)+' hours and '+CONVERT(NVARCHAR(3),@engine_minutes)+' minutes ago as process ID '+CONVERT(NVARCHAR,SERVERPROPERTY('ProcessID'));
			END;
			IF (@iscluster=0) 
			BEGIN 
				PRINT 'The instance "'+CONVERT(NVARCHAR,SERVERPROPERTY('ServerName'))+'" is non-clustered, runs on the host "'+CONVERT(NVARCHAR,SERVERPROPERTY('ComputerNamePhysicalNetBIOS'))+'", ip "'+@ip+'", domain "'+@Domain+'"'; 
			END;
	END;


--===============================================================================================================================--
--====================================================== SERVICES STATUS ========================================================--
--===============================================================================================================================--

	-- ### Is the server in single mode option?
	DECLARE @IsSingleUser SQL_VARIANT; SELECT @IsSingleUser=SERVERPROPERTY('IsSingleUser');
	IF (@IsSingleUser<>0) 
	BEGIN 
		PRINT '[!] SQL Server is configured in Single Mode (startup option -m)'; PRINT '[!] Single-user mode restricts connections to members of the sysadmin fixed server role'; PRINT '[!] http://msdn.microsoft.com/en-us/library/ms188236.aspx'; PRINT '';
	END;

	-- ### Services variables
	DECLARE @SrvAccDBEngine NVARCHAR(256), @SrvAccAgent NVARCHAR(128); 

	IF (CONVERT(INT,@@microsoftversion)>=171051460) --SQL2008R2SP1 or greater
	BEGIN
		SELECT @SrvAccDBEngine=[service_account] FROM [sys].[dm_server_services] WHERE [servicename]='SQL Server (MSSQLSERVER)'; 
		SELECT @SrvAccAgent=[service_account] FROM [sys].[dm_server_services] WHERE [servicename]='SQL Server Agent (MSSQLSERVER)';
	END;
	ELSE
	BEGIN
		-- Credit for this block to http://sqlandme.com/2013/08/20/sql-service-get-sql-server-service-account-using-t-sql/ by Vishal@SqlAndMe.com
		EXEC       [master].[sys].[xp_instance_regread]
					  @rootkey      = N'HKEY_LOCAL_MACHINE',
					  @key          = N'SYSTEM\CurrentControlSet\Services\MSSQLServer',
					  @value_name   = N'ObjectName',
					  @value        = @SrvAccDBEngine OUTPUT;
 
		EXEC       [master].[sys].[xp_instance_regread]
					  @rootkey      = N'HKEY_LOCAL_MACHINE',
					  @key          = N'SYSTEM\CurrentControlSet\Services\SQLServerAgent',
					  @value_name   = N'ObjectName',
					  @value        = @SrvAccAgent OUTPUT;
	END;

	IF CHARINDEX('@',@SrvAccAgent,0)>0 BEGIN SELECT @SrvAccAgent='%'+LEFT(@SrvAccAgent,CHARINDEX('@',@SrvAccAgent,0)-1); END;

	-- ### Engine service running info
	PRINT 'The engine has been up since '+CONVERT(NVARCHAR(16),@tempDBcreate,101)+' '+CONVERT(NVARCHAR(16),@tempDBcreate,108)+', '+CONVERT(NVARCHAR(6),@engine_hours)+' hours and '+CONVERT(NVARCHAR(3),@engine_minutes)+' minutes ago as process ID '+CONVERT(NVARCHAR,SERVERPROPERTY('ProcessID'))+' under ['+@SrvAccDBEngine+']';

	-- ### Is the agent service running?
	DECLARE @SQLAgentStart DATETIME; SELECT @SQLAgentStart=[login_time] FROM [sys].[dm_exec_sessions] WHERE [login_name] LIKE @SrvAccAgent AND [program_name] LIKE 'SQLAgent - Generic Refresher%'; 
	IF EXISTS (SELECT TOP 1 [login_name] FROM [sys].[dm_exec_sessions] WHERE [login_name] LIKE @SrvAccAgent AND [program_name] LIKE 'SQLAgent%') 
	BEGIN
		PRINT 'The agent was last started on '+CONVERT(NVARCHAR(16),@SQLAgentStart,101)+' '+CONVERT(NVARCHAR(16),@SQLAgentStart,108)+', '+CONVERT(NVARCHAR,DATEDIFF(hh,@SQLAgentStart,GETDATE()))+' hours ago, and runs under ['+@SrvAccAgent+']';
	END;
	ELSE
	BEGIN
		PRINT '[!] The SQL Agent service is NOT in running status';
		--IF (@iscluster=0)
		--BEGIN
			--PRINT 'EXEC master.sys.xp_servicecontrol N''querystate'',N''SQLServerAGENT'';  --Query current status'; PRINT 'EXEC master.sys.xp_servicecontrol N''start'',N''SQLServerAGENT''; --Start the service';
			--PRINT 'EXEC xp_cmdshell ''SC QUERY SQLSERVERAGENT'''; --PRINT 'EXEC xp_cmdshell ''SC START SQLSERVERAGENT''';
		--END;
	END;

	-- ### Traces, Server Event Notifications, Extended Events and Server Triggers count
	DECLARE @traces INT; SELECT @traces=COUNT([id]) FROM [sys].[traces] WHERE [stop_time] IS NULL;
	DECLARE @server_event_notifications INT; SELECT @server_event_notifications=COUNT([name]) FROM [sys].[server_event_notifications];
	DECLARE @xe_sessions INT; IF (CONVERT(INT,@@microsoftversion)>=171051460) /*SQL2008R2SP1 or greater*/ BEGIN	SELECT @xe_sessions=COUNT([name]) FROM [sys].[dm_xe_sessions]; END;
	DECLARE @server_triggers INT; SELECT @server_triggers=COUNT([name]) FROM [sys].[server_triggers] WHERE [is_disabled]<>1;
	PRINT CONVERT(NVARCHAR(32),@traces)+' traces, '+CONVERT(NVARCHAR(32),@server_event_notifications)+' server event notifications, '+CONVERT(NVARCHAR(32),ISNULL(@xe_sessions,0))+' extended events sessions, and '+CONVERT(NVARCHAR(32),@server_triggers)+' server triggers currently running';

	PRINT ''; -- Print break


--===============================================================================================================================--
--======================================================= FILES STATUSES ========================================================--
--===============================================================================================================================--

	DECLARE @dbs INT; SELECT @dbs=COUNT([state_desc]) FROM [sys].[databases];
	DECLARE @dbso INT; SELECT @dbso=COUNT([state_desc]) FROM [sys].[databases] WHERE [state_desc]='ONLINE';
	DECLARE @dbmu INT; SELECT @dbmu=COUNT([user_access_desc]) FROM [sys].[databases] WHERE [user_access_desc]='MULTI_USER';
	DECLARE @dbf INT; SELECT @dbf=COUNT([state_desc]) FROM [sys].[master_files];
	DECLARE @dbfo INT; SELECT @dbfo=COUNT([state_desc]) FROM [sys].[master_files] WHERE [state_desc]='ONLINE';

	-- ### Check if all databases are in MULTI_USER and ONLINE status
	IF (@dbs = @dbso) AND (@dbs = @dbmu)
	BEGIN 
		PRINT 'All '+CONVERT(NVARCHAR(3),@dbs)+' databases attached to the server are in MULTI_USER access and ONLINE status';
	END;
	IF (@dbs > @dbso) OR (@dbs > @dbmu) 
	BEGIN 
		IF (@dbs = @dbso) 
		BEGIN 
			PRINT 'All '+CONVERT(NVARCHAR(3),@dbs)+' databases attached to the server are in ONLINE status';
		END;
		ELSE IF (@dbs > @dbso)  
		BEGIN
			PRINT '[!] Only '+CONVERT(NVARCHAR(3),@dbso)+' databases are in online status out of '+CONVERT(NVARCHAR(5),@dbs)+' attached on the server';
		END; 
	
		IF (@dbs = @dbmu)
			BEGIN 
				PRINT 'All '+CONVERT(NVARCHAR(3),@dbs)+' databases attached to the server are in MULTI_USER access status';
			END;
		ELSE IF (@dbs > @dbmu)
		BEGIN 
			PRINT '[!] Only '+CONVERT(NVARCHAR(3),@dbmu)+' databases are in multi_user access status out of '+CONVERT(NVARCHAR(5),@dbs)+' attached to the server';
		END; 
	END;

	-- ### Check if all data and log files are online
	IF (@dbf = @dbfo) 
	BEGIN 
		PRINT 'All '+CONVERT(NVARCHAR(3),@dbf)+' data and log files used by the databases on the server are in ONLINE status';
	END;
	ELSE
	BEGIN
		PRINT '[!] Only '+CONVERT(NVARCHAR(3),@dbfo)+' out of '+CONVERT(NVARCHAR(3),@dbf)+' of the log and data files used by the databases attached are in online status';
	END;


--===============================================================================================================================--
--======================================================= FILES' SIZES ==========================================================--
--===============================================================================================================================--

        DECLARE @LogFilesTotalSize INT; SELECT @LogFilesTotalSize=SUM(([size]*8)/1024) FROM [sys].[master_files] WHERE [type_desc]='LOG' GROUP BY [type_desc];
        DECLARE @DataFilesTotalSize INT; SELECT @DataFilesTotalSize=SUM(([size]*8)/1024) FROM [sys].[master_files] WHERE [type_desc]='ROWS' GROUP BY [type_desc];
        PRINT 'The database log files use '+CONVERT(NVARCHAR(32),@LogFilesTotalSize)+' MB, and the data files use '+CONVERT(NVARCHAR(32),@DataFilesTotalSize)+' MB, for a total of '+CONVERT(NVARCHAR(32),@DataFilesTotalSize+@LogFilesTotalSize)+' MB';

	PRINT ''; -- Print break


--===============================================================================================================================--
--===================================================== SERVER RESOURCES ========================================================--
--===============================================================================================================================--

	-- ### Processors' data
	DECLARE @cpu_name NVARCHAR(56); DECLARE @cpu_info TABLE ([name] NVARCHAR(MAX) NULL); INSERT INTO @cpu_info EXEC [sys].[xp_cmdshell] 'wmic cpu get name'; DELETE @cpu_info WHERE [name] IS NULL OR [name] LIKE '%name%'; SELECT TOP 1 @cpu_name=[name] FROM @cpu_info;
	IF (CONVERT(INT,@@microsoftversion)>=171051460) --SQL2008R2SP1 or greater
	BEGIN
			/* Credit for this block to Basit Farooq http://basitaalishan.com/2014/01/22/get-sql-server-physical-cores-physical-and-virtual-cpus-and-processor-type-information-using-t-sql-script */
			DECLARE @number_of_virtual_cpus NVARCHAR(4), @number_of_cores_per_cpu NVARCHAR(4), @number_of_physical_cpus NVARCHAR(4), @total_number_of_cores NVARCHAR(4), @cpu_category NVARCHAR(12);
			DECLARE @xp_msver TABLE ([idx] [INT] NULL,[c_name] [NVARCHAR](100) NULL,[int_val] [FLOAT] NULL,[c_val] [NVARCHAR](128) NULL); 
			INSERT INTO @xp_msver EXEC ('[master]..[xp_msver]'); 
			WITH [ProcessorInfo] AS (SELECT ([cpu_count] / [hyperthread_ratio]) AS [number_of_physical_cpus],CASE WHEN [hyperthread_ratio] = [cpu_count] THEN [cpu_count] ELSE (([cpu_count] - [hyperthread_ratio]) / ([cpu_count] / [hyperthread_ratio])) END AS [number_of_cores_per_cpu],CASE WHEN [hyperthread_ratio] = [cpu_count] THEN [cpu_count] ELSE ([cpu_count] / [hyperthread_ratio]) * (([cpu_count] - [hyperthread_ratio]) / ([cpu_count] / [hyperthread_ratio])) END AS [total_number_of_cores],[cpu_count] AS [number_of_virtual_cpus],(SELECT [c_val] FROM @xp_msver WHERE [c_name] = 'Platform') AS [cpu_category] FROM [sys].[dm_os_sys_info])
			SELECT @number_of_physical_cpus=[ProcessorInfo].[number_of_physical_cpus],@number_of_cores_per_cpu=[ProcessorInfo].[number_of_cores_per_cpu],@total_number_of_cores=[ProcessorInfo].[total_number_of_cores],@number_of_virtual_cpus=[ProcessorInfo].[number_of_virtual_cpus],@cpu_category=LTRIM(RIGHT([ProcessorInfo].[cpu_category], CHARINDEX('x', [ProcessorInfo].[cpu_category]) - 1)) FROM [ProcessorInfo];	
			PRINT 'Processor '+REPLACE(REPLACE((REPLACE(REPLACE(REPLACE(@cpu_name,' ','<>'),'><',''),'<>',' ')), CHAR(13), ''), CHAR(10), '')+'with ' +@number_of_physical_cpus+' cpus having '+@number_of_cores_per_cpu++' cores each for a total of '+@total_number_of_cores+' cores and '+@number_of_virtual_cpus+' virtual on '+@cpu_category;
	END;
	ELSE
	BEGIN
			WITH [ProcessorInfoLow] AS (SELECT ([cpu_count] / [hyperthread_ratio]) AS [number_of_physical_cpus],CASE WHEN [hyperthread_ratio] = [cpu_count] THEN [cpu_count] ELSE (([cpu_count] - [hyperthread_ratio]) / ([cpu_count] / [hyperthread_ratio])) END AS [number_of_cores_per_cpu], CASE WHEN [hyperthread_ratio] = [cpu_count] THEN [cpu_count] ELSE ([cpu_count] / [hyperthread_ratio]) * (([cpu_count] - [hyperthread_ratio]) / ([cpu_count] / [hyperthread_ratio])) END AS [total_number_of_cores],[cpu_count] AS [number_of_virtual_cpus] FROM [sys].[dm_os_sys_info]    )
			SELECT @number_of_physical_cpus=[ProcessorInfoLow].[number_of_physical_cpus],@number_of_cores_per_cpu=[ProcessorInfoLow].[number_of_cores_per_cpu],@total_number_of_cores=[ProcessorInfoLow].[total_number_of_cores],@number_of_virtual_cpus=[ProcessorInfoLow].[number_of_virtual_cpus] FROM [ProcessorInfoLow];
			PRINT 'Processor '+REPLACE(REPLACE((REPLACE(REPLACE(REPLACE(@cpu_name,' ','<>'),'><',''),'<>',' ')), CHAR(13), ''), CHAR(10), '')+'with '+@number_of_physical_cpus+' cpus having '+@number_of_cores_per_cpu++' cores each for a total of '+@total_number_of_cores+' cores and '+@number_of_virtual_cpus+' virtual';
	END;
	
	-- ### CPU Use and MAXDOP
	/* Credit for this block to Benjamin Nevarez http://http://sqlblog.com/blogs/ben_nevarez/archive/2009/07/26/getting-cpu-utilization-data-from-sql-server.aspx */ 
	DECLARE @CPU_Print NVARCHAR(1024), @CPU_TotalUse INT, @CPU_SQL INT, @CPU_Other INT; SELECT @CPU_TotalUse=(100-[y].[SystemIdle]) ,@CPU_SQL=[y].[SQLProcessUtilization],@CPU_Other=(100-[y].[SystemIdle]-[y].[SQLProcessUtilization]) FROM (SELECT [x].[record].[value]('(./Record/@id)[1]' ,'int') AS [record_id],[x].[record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]' ,'int') AS [SystemIdle],[x].[record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]' ,'int') AS [SQLProcessUtilization],[x].[timestamp] FROM (SELECT TOP 1 [timestamp],CONVERT(XML ,[record]) AS [record] FROM [sys].[dm_os_ring_buffers] WHERE [ring_buffer_type]=N'RING_BUFFER_SCHEDULER_MONITOR' AND [record] LIKE '%<SystemHealth>%' ORDER BY [timestamp] DESC) AS [x]) AS [y];
	SET @CPU_Print=N'CPU use at '+CONVERT(NVARCHAR(3),@CPU_TotalUse)+N'%, '+CONVERT(NVARCHAR(3),@CPU_SQL)+N'% used by this instance, and '+CONVERT(NVARCHAR(3),@CPU_Other)+N'% by other processes. ';

	DECLARE @Parallelism_MAXDOP INT, @Parallelism_CostThreshold INT; SELECT @Parallelism_MAXDOP=CONVERT(INT,[value]) FROM [sys].[configurations] WHERE [name]='max degree of parallelism'; SELECT @Parallelism_CostThreshold=CONVERT(INT,[value]) FROM [sys].[configurations] WHERE [name]='cost threshold for parallelism';		
	
	PRINT ISNULL(@CPU_Print,'')+N'Max degree of parallelism at '+CONVERT(NVARCHAR(8),@Parallelism_MAXDOP)+' with a cost threshold of '+CONVERT(NVARCHAR(8),@Parallelism_CostThreshold);

	-- ### Memory data
	DECLARE @TotalServerMemory INT; SELECT @TotalServerMemory=[cntr_value]/1024 FROM [sys].[dm_os_performance_counters] WHERE	[object_name] IN ('SQLServer:Memory Manager') AND [counter_name] IN ('Total Server Memory (KB)');
	DECLARE @TargetServerMemory INT; SELECT @TargetServerMemory=[cntr_value]/1024 FROM [sys].[dm_os_performance_counters] WHERE [object_name] IN ('SQLServer:Memory Manager') AND [counter_name] IN ('Target Server Memory (KB)');
	DECLARE @max_buff_mem SQL_VARIANT; SELECT @max_buff_mem=[value] FROM [sys].[configurations] WHERE [name] LIKE '%max server memory%';
	DECLARE @os_memory INT;

	IF (CONVERT(INT,@@microsoftversion)>=171051460) --SQL2008R2SP1 or greater
	BEGIN
		DECLARE @memorymbavail INT, @memorypercentavail DECIMAL(5,2); SELECT @os_memory= [total_physical_memory_kb]/1024, @memorymbavail=([available_physical_memory_kb]/1024), @memorypercentavail=(CONVERT(DECIMAL(5,2),((CONVERT(DECIMAL(30,2),[available_physical_memory_kb])/CONVERT(DECIMAL(30,2),[total_physical_memory_kb]))*100))) FROM [sys].[dm_os_sys_memory];
		IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(20),@os_memory)+' MB of RAM with '+CONVERT(NVARCHAR(32),@memorymbavail)+' available ('+CONVERT(NVARCHAR(5),@memorypercentavail)+'%), '+CONVERT(NVARCHAR(32),@TotalServerMemory)+' currently assigned for SQL which is targeting '+CONVERT(NVARCHAR(32),@TargetServerMemory)+' and maxed at '+CONVERT(NVARCHAR(20),@max_buff_mem); END;
	END;
	ELSE
	BEGIN
		SET @cmd = N'SELECT @os_memory=(physical_memory_in_bytes/1024)/1024 FROM [master].[sys].[dm_os_sys_info];';
		EXEC [master].[sys].[sp_executesql] @cmd, N'@os_memory NVARCHAR(8) out', @os_memory OUTPUT;
		IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(20),@os_memory)+' MB of memory with '+CONVERT(NVARCHAR(32),@TotalServerMemory)+' currently assigned for SQL which is targeting '+CONVERT(NVARCHAR(32),@TargetServerMemory)+' and maxed at '+CONVERT(NVARCHAR(20),@max_buff_mem); END;
	END;

	DECLARE @BufferCHR DECIMAL(10,2); SET @BufferCHR=((SELECT CONVERT(DECIMAL(16,2),[cntr_value]) FROM [sys].[dm_os_performance_counters] WHERE [object_name] ='SQLServer:Buffer Manager'	AND [counter_name]='Buffer cache hit ratio') / (SELECT CONVERT(DECIMAL(16,2),[cntr_value]) FROM [sys].[dm_os_performance_counters] WHERE [object_name] ='SQLServer:Buffer Manager' AND [counter_name]='Buffer cache hit ratio base'))*100;
	DECLARE @PLE BIGINT; SELECT @PLE=[cntr_value] FROM [sys].[dm_os_performance_counters] WHERE [object_name] LIKE '%Manager%' AND [counter_name]='Page life expectancy';

	IF (CONVERT(INT,@@microsoftversion)>=171051460) --SQL2008R2SP1 or greater
	BEGIN
		DECLARE @MemoryPlanCache INT; SELECT @MemoryPlanCache=[allocations_kb]/1024 FROM [sys].[dm_os_memory_brokers] WHERE [memory_broker_type]='MEMORYBROKER_FOR_CACHE';
		DECLARE @BufferDBPages INT; SELECT @BufferDBPages= ([cntr_value]*8)/1024 FROM [sys].[dm_os_performance_counters] WHERE [object_name] IN ('SQLServer:Buffer Manager') AND  [counter_name] = 'Database pages';
		IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(64),@BufferDBPages)+' MB of memory used as buffer for database pages ('+CONVERT(NVARCHAR(16),CONVERT(DECIMAL(4,2),(CONVERT(DECIMAL(16,4),CONVERT(DECIMAL(16,5),@BufferDBPages) / CONVERT(DECIMAL(16,5),@TotalServerMemory)))*100))+'%), Cache hit ratio at '+CONVERT(NVARCHAR(6),@BufferCHR)+'%, page life expectancy at '+CONVERT(NVARCHAR(15),@PLE)+' secs ('+CONVERT(NVARCHAR(15),@PLE/60)+' min)'; ; END;
	END;

	IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(16),@BufferPageReads_sec)+' ('+CONVERT(NVARCHAR(8),((@BufferPageReads_sec*8)/1024))+' MB) page reads, '+CONVERT(NVARCHAR(16),@BufferPageWrites_sec)+' ('+CONVERT(NVARCHAR(8),((@BufferPageWrites_sec*8)/1024))+' MB) page writes, '+CONVERT(NVARCHAR(16),@PageSplits_sec)+' ('+CONVERT(NVARCHAR(16),( (@PageSplits_sec*8)/1024) )+' MB) page splits, '+CONVERT(NVARCHAR(16),@CheckpointPages_sec)+' ('+CONVERT(NVARCHAR(16),( (@CheckpointPages_sec*8)/1024) )+' MB) checkpoint pages, and '+CONVERT(NVARCHAR(16),@BufferLazyWrites_sec)+' lazy writes per second'; END;

	-- ### Cached objects
	DECLARE @exec_plans_total_count BIGINT; SELECT @exec_plans_total_count=COUNT(*) FROM [sys].[dm_exec_cached_plans];
	DECLARE @exec_plans_total_mb BIGINT; SELECT @exec_plans_total_mb=SUM(CONVERT(BIGINT,[size_in_bytes]))/1024/1024 FROM [sys].[dm_exec_cached_plans]
	DECLARE @exec_plans_tenorless_mb BIGINT; SELECT @exec_plans_tenorless_mb=SUM(CONVERT(BIGINT,[size_in_bytes]))/1024/1024 FROM [sys].[dm_exec_cached_plans] WHERE [usecounts]<=10;
	PRINT CONVERT(NVARCHAR(64),@MemoryPlanCache)+' MB used for cached objects ('+CONVERT(NVARCHAR(16),CONVERT(DECIMAL(4,2),(CONVERT(DECIMAL(16,4),CONVERT(DECIMAL(16,5),@MemoryPlanCache) / CONVERT(DECIMAL(16,5),@TotalServerMemory)))*100))+'%), '+CONVERT(NVARCHAR(32),@exec_plans_total_count)+' exec plans stored using '+CONVERT(NVARCHAR(32),@exec_plans_total_mb)+' MB, '+CONVERT(NVARCHAR(32),@exec_plans_tenorless_mb)+' MB ('+CONVERT(NVARCHAR(5),CONVERT(DECIMAL(3,1),CONVERT(DECIMAL(32,2),@exec_plans_tenorless_mb)/CONVERT(DECIMAL(32,2),@exec_plans_total_mb)*100))+'%) for plans used ten times or less'

	PRINT ''; -- Print break

	-- ### Check if perfmon counters are missing
	IF @os_performance_counters=0
	BEGIN
		PRINT '[!] The SQL server performance counters are missing on the server';
	END;

	-- ### Configured vs running values
	DECLARE @value_valueinuse INT; SELECT @value_valueinuse=SUM(CASE WHEN [value]<>[value_in_use] THEN 1 ELSE 0 END) FROM [sys].[configurations];
	IF @value_valueinuse>0
	BEGIN
		PRINT '[!] Some server wide configuration options have been set but not applied and will take effect on the next restart';
	END;


--===============================================================================================================================--
--==================================================== METRICS AND STATS ========================================================--
--===============================================================================================================================--

	-- ### Sessions
	DECLARE @Transactions INT; SELECT @Transactions=[cntr_value] FROM [sys].[dm_os_performance_counters] WHERE [object_name] IN ('SQLServer:Transactions') AND [counter_name] IN ('Transactions');
	DECLARE @TransactionsBlocked INT; SELECT @TransactionsBlocked = [cntr_value] FROM [sys].[dm_os_performance_counters] WHERE ([object_name]='SQLServer:General Statistics' AND [counter_name]='Processes blocked');
	DECLARE @connections INT; SELECT @connections=[cntr_value] FROM [sys].[dm_os_performance_counters] WHERE ([object_name]='SQLServer:General Statistics' AND [counter_name]='User Connections');
	DECLARE @ConnectionsMemory INT; SELECT @ConnectionsMemory= [cntr_value] FROM [sys].[dm_os_performance_counters] WHERE	[object_name] IN ('SQLServer:Memory Manager') AND [counter_name] IN ('Connection Memory (KB)');

	IF @os_performance_counters<>0 
	BEGIN
			PRINT CONVERT(NVARCHAR(8),@Logins_sec)+ ' logins and '+CONVERT(NVARCHAR(8),@Logouts_sec)+' logouts per second, '+ CONVERT(NVARCHAR(8),@connections)+' concurrent user connections using '+CONVERT(NVARCHAR(16),@ConnectionsMemory/1024)+' MB of memory';
			PRINT CONVERT(NVARCHAR(16),@BatchRequests_sec)+' batch requests, '+CONVERT(NVARCHAR(16),@Transactions_sec)+' transactions, and '+CONVERT(NVARCHAR(16),@WriteTransactions_sec)+' writting transactions per second, '+CONVERT(NVARCHAR(16),@Transactions)+' currently executing and '+CONVERT(NVARCHAR(8),@TransactionsBlocked)+' blocked'; 
			PRINT CONVERT(NVARCHAR(8),@Compilations_sec)+' compilations, '+CONVERT(NVARCHAR(8),@ReCompilations_sec)+' recompilations, '+CONVERT(NVARCHAR(8),@QueryOptimizations_sec)+' query optimizations per second';
	END;

	-- ### Sessions' isolation levels
	DECLARE @IsolationReadUncomitted INT, @IsolationReadCommitted INT, @IsolationRepeatable INT, @IsolationSerializable INT, @IsolationSnapshot INT;
	SELECT @IsolationReadUncomitted=COUNT([transaction_isolation_level]) FROM [sys].[dm_exec_sessions] WHERE [transaction_isolation_level]=1;
	SELECT @IsolationReadCommitted=COUNT([transaction_isolation_level]) FROM [sys].[dm_exec_sessions] WHERE [transaction_isolation_level]=2;
	SELECT @IsolationRepeatable=COUNT([transaction_isolation_level]) FROM [sys].[dm_exec_sessions] WHERE [transaction_isolation_level]=3;
	SELECT @IsolationSerializable=COUNT([transaction_isolation_level]) FROM [sys].[dm_exec_sessions] WHERE [transaction_isolation_level]=4;
	SELECT @IsolationSnapshot=COUNT([transaction_isolation_level]) FROM [sys].[dm_exec_sessions] WHERE [transaction_isolation_level]=5;

	IF (@IsolationReadUncomitted+@IsolationRepeatable+@IsolationSerializable+@IsolationSnapshot)>0
	BEGIN
		PRINT 'The sessions'' isolation levels are '+ CONVERT(NVARCHAR(32),@IsolationReadUncomitted) +' Read-Uncomitted, '+ CONVERT(NVARCHAR(32),@IsolationReadCommitted) +' Read-Committed, '+ CONVERT(NVARCHAR(32),@IsolationRepeatable) +' Repeatable, '+  CONVERT(NVARCHAR(32),@IsolationSerializable) +' Serializable, and '+ CONVERT(NVARCHAR(32),@IsolationSnapshot) +' Snapshot';
	END;

	-- ### Long running transactions
	DECLARE @LongRunningTrans INT; SELECT @LongRunningTrans=COUNT([er].[session_id]) FROM [master].[sys].[dm_exec_requests] [er] LEFT JOIN [master].[sys].[dm_exec_sessions] [es] ON [er].[session_id]=[es].[session_id] WHERE [es].[is_user_process]=1 AND DATEDIFF(mi,[er].[start_time],GETDATE())>1 AND [er].[wait_type]<>'TRACEWRITE';
	IF @LongRunningTrans>0
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(8),@LongRunningTrans)+' transactions have been running for more than 1 minute';
	END;

	-- ### Cursors executing
	DECLARE @CursorsExec INT, @CursorOldest DATETIME; SELECT @CursorsExec=COUNT([session_id]), @CursorOldest=MIN([creation_time]) FROM [sys].[dm_exec_cursors](0) WHERE [session_id]<>@@SPID GROUP BY [session_id];
	IF @CursorsExec>0
	BEGIN
			PRINT '[!] '+CONVERT(NVARCHAR(32),ISNULL(@CursorsExec,0))+' cursors currently executing on the server, the oldest has been running since '+CONVERT(NVARCHAR(32),ISNULL(@CursorOldest,GETDATE()),120)+', '+CONVERT(NVARCHAR(32),DATEDIFF(ss,ISNULL(@CursorOldest,GETDATE()),GETDATE()))+' seconds ago';
	END;

	-- ### Deadlocks
	DECLARE @Deadlocks INT; SELECT @Deadlocks=[cntr_value] FROM [sys].[dm_os_performance_counters] WHERE [counter_name]='Number of Deadlocks/sec' AND [instance_name]='_Total';
	IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(32),@Deadlocks)+' deadlocks have taken place since the last time the server started'; END;

	PRINT ''; --Break

	-- ### Top wait	
	DECLARE @WaitTypeCurrentMain NVARCHAR(64), @WaitTypeCurrentMainWaits INT; SELECT TOP 1 @WaitTypeCurrentMain=[wait_type], @WaitTypeCurrentMainWaits=COUNT([wait_type]) FROM [sys].[dm_os_waiting_tasks] WHERE [wait_type] NOT IN (N'REQUEST_FOR_DEADLOCK_SEARCH',N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',N'SQLTRACE_BUFFER_FLUSH',N'LAZYWRITER_SLEEP',N'XE_TIMER_EVENT',N'XE_DISPATCHER_WAIT',N'FT_IFTS_SCHEDULER_IDLE_WAIT',N'LOGMGR_QUEUE',N'CHECKPOINT_QUEUE',N'BROKER_TO_FLUSH',N'BROKER_TASK_STOP',N'BROKER_EVENTHANDLER',N'SLEEP_TASK',N'WAITFOR',N'DBMIRROR_DBM_MUTEX',N'DBMIRROR_EVENTS_QUEUE',N'DBMIRRORING_CMD',N'DISPATCHER_QUEUE_SEMAPHORE',N'BROKER_RECEIVE_WAITFOR',N'CLR_AUTO_EVENT',N'DIRTY_PAGE_POLL',N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',N'ONDEMAND_TASK_QUEUE',N'FT_IFTSHC_MUTEX',N'CLR_MANUAL_EVENT',N'SP_SERVER_DIAGNOSTICS_SLEEP',N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP') GROUP BY [wait_type] ORDER BY COUNT([wait_type]) DESC;
	DECLARE @Waits BIGINT; SELECT @Waits=SUM([cntr_value]) FROM [sys].[dm_os_performance_counters] WHERE [object_name]='SQLServer:Wait Statistics' AND [instance_name]='Waits started per second';
	IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(32),@Waits)+' waits initiated per second, the top wait type at this moment is "'+REPLACE(@WaitTypeCurrentMain,'  ','')+'" with '+CONVERT(NVARCHAR(32),@WaitTypeCurrentMainWaits); END;

	DECLARE @WaitsCPU INT; SELECT @WaitsCPU=COUNT(DISTINCT [session_id]) FROM [sys].[dm_os_waiting_tasks] WHERE	[wait_type]='SOS_SCHEDULER_YIELD';
	DECLARE @WaitsCXPACKET INT; SELECT @WaitsCXPACKET=COUNT(DISTINCT [session_id]) FROM [sys].[dm_os_waiting_tasks] WHERE [wait_type]='CXPACKET';
	DECLARE	@WaitsIO INT; SELECT @WaitsIO=COUNT(DISTINCT [session_id]) FROM [sys].[dm_os_waiting_tasks] WHERE [wait_type] IN ('IO_COMPLETION' ,'PAGEIOLATCH_DT' ,'PAGEIOLATCH_EX' ,'PAGEIOLATCH_KP' ,'PAGEIOLATCH_NL' ,'PAGEIOLATCH_SH' ,'PAGEIOLATCH_UP' ,'PAGELATCH_DT' ,'PAGELATCH_EX' ,'PAGELATCH_KP' ,'PAGELATCH_NL' ,'PAGELATCH_SH' ,'PAGELATCH_UP' ,'PREEMPTIVE_OS_FILEOPS' ,'SLEEP_BPOOL_FLUSH' ,'WRITE_COMPLETION' ,'WRITELOG');
	DECLARE @IO_pend_requests INT; SELECT @IO_pend_requests=COUNT([io_pending]) FROM [sys].[dm_io_pending_io_requests] WHERE [io_type]='disk' AND [io_pending]=1;
	PRINT CONVERT(NVARCHAR(64),@IO_pend_requests)+' pending IO requests, '+CONVERT(NVARCHAR(16),@WaitsIO)++' waits initiated on IO, '+CONVERT(NVARCHAR(16),@WaitsCPU)+' on CPU, and '+CONVERT(NVARCHAR(16),@WaitsCXPACKET)+' on parallelism';

	-- ### Memory grants
	DECLARE @MemoryGrants INT; SELECT @MemoryGrants=[cntr_value] FROM [sys].[dm_os_performance_counters] WHERE	[object_name] IN ('SQLServer:Memory Manager') AND [counter_name] IN ('Memory Grants Outstanding');
	DECLARE @MemoryGrantsPending INT; SELECT @MemoryGrantsPending=[cntr_value] FROM [sys].[dm_os_performance_counters] WHERE [object_name] IN ('SQLServer:Memory Manager') AND [counter_name] IN ('Memory Grants Pending');

	IF (CONVERT(INT,@@microsoftversion)>=171051460) --SQL2008R2SP1 or greater
	BEGIN
		DECLARE @MemoryGrantsReserve INT; SELECT @MemoryGrantsReserve=[allocations_kb]/1024 FROM [sys].[dm_os_memory_brokers] WHERE [memory_broker_type]='MEMORYBROKER_FOR_RESERVE';
		IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(64),@MemoryGrants)+' existing memory grants, and '+CONVERT(NVARCHAR(64),@MemoryGrantsPending)+' pending, with '+CONVERT(NVARCHAR(64),@MemoryGrantsReserve)+' MB of memory reserved for executions ('+CONVERT(NVARCHAR(16),CONVERT(DECIMAL(4,2),(CONVERT(DECIMAL(16,4),CONVERT(DECIMAL(16,5),@MemoryGrantsReserve) / CONVERT(DECIMAL(16,5),@TotalServerMemory)))*100))+'%)'; END;
	END;
	ELSE
	BEGIN
		IF @os_performance_counters<>0 BEGIN PRINT CONVERT(NVARCHAR(64),@MemoryGrants)+' memory grants and '+CONVERT(NVARCHAR(64),@MemoryGrantsPending)+' pending'; END;
	END;

	DECLARE @WaitTypeAggregatedMain NVARCHAR(64), @WaitTypeAggregatedPercentage DECIMAL(5,2); 
	/* Credit for this block to Paul Randal http://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts */ 
	;WITH [Waits] AS (SELECT [wait_type], [wait_time_ms] / 1000.0 AS [WaitS], ([wait_time_ms] - [signal_wait_time_ms]) / 1000.0 AS [ResourceS], [signal_wait_time_ms] / 1000.0 AS [SignalS], [waiting_tasks_count] AS [WaitCount],100.0 * [wait_time_ms] / SUM ([wait_time_ms]) OVER() AS [Percentage],ROW_NUMBER() OVER(ORDER BY [wait_time_ms] DESC) AS [RowNum] FROM [sys].[dm_os_wait_stats]     WHERE [wait_type] NOT IN (         N'BROKER_EVENTHANDLER',             N'BROKER_RECEIVE_WAITFOR',         N'BROKER_TASK_STOP',                N'BROKER_TO_FLUSH',         N'BROKER_TRANSMITTER',              N'CHECKPOINT_QUEUE',         N'CHKPT',                           N'CLR_AUTO_EVENT',         N'CLR_MANUAL_EVENT',                N'CLR_SEMAPHORE',         N'DBMIRROR_DBM_EVENT',              N'DBMIRROR_EVENTS_QUEUE',         N'DBMIRROR_WORKER_QUEUE',           N'DBMIRRORING_CMD',         N'DIRTY_PAGE_POLL',                 N'DISPATCHER_QUEUE_SEMAPHORE',         N'EXECSYNC',                        N'FSAGENT',         N'FT_IFTS_SCHEDULER_IDLE_WAIT',     N'FT_IFTSHC_MUTEX',         N'HADR_CLUSAPI_CALL',               N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',         N'HADR_LOGCAPTURE_WAIT',            N'HADR_NOTIFICATION_DEQUEUE',         N'HADR_TIMER_TASK',                 N'HADR_WORK_QUEUE',         N'KSOURCE_WAKEUP',                  N'LAZYWRITER_SLEEP',         N'LOGMGR_QUEUE',                    N'ONDEMAND_TASK_QUEUE',         N'PWAIT_ALL_COMPONENTS_INITIALIZED',         N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',         N'QDS_SHUTDOWN_QUEUE',         N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',         N'REQUEST_FOR_DEADLOCK_SEARCH',     N'RESOURCE_QUEUE',         N'SERVER_IDLE_CHECK',               N'SLEEP_BPOOL_FLUSH',         N'SLEEP_DBSTARTUP',                 N'SLEEP_DCOMSTARTUP',         N'SLEEP_MASTERDBREADY',             N'SLEEP_MASTERMDREADY',         N'SLEEP_MASTERUPGRADED',            N'SLEEP_MSDBSTARTUP',         N'SLEEP_SYSTEMTASK',                N'SLEEP_TASK',         N'SLEEP_TEMPDBSTARTUP',             N'SNI_HTTP_ACCEPT',         N'SP_SERVER_DIAGNOSTICS_SLEEP',     N'SQLTRACE_BUFFER_FLUSH',         N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',         N'SQLTRACE_WAIT_ENTRIES',           N'WAIT_FOR_RESULTS',         N'WAITFOR',                         N'WAITFOR_TASKSHUTDOWN',         N'WAIT_XTP_HOST_WAIT',              N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',         N'WAIT_XTP_CKPT_CLOSE',             N'XE_DISPATCHER_JOIN',         N'XE_DISPATCHER_WAIT',              N'XE_TIMER_EVENT')     AND [waiting_tasks_count] > 0  ) SELECT TOP 1     @WaitTypeAggregatedMain=MAX ([W1].[wait_type]),     @WaitTypeAggregatedPercentage=CAST (MAX ([W1].[Percentage]) AS DECIMAL (5,2)) FROM [Waits] AS [W1] INNER JOIN [Waits] AS [W2]     ON [W2].[RowNum] <= [W1].[RowNum] GROUP BY [W1].[RowNum] HAVING SUM ([W2].[Percentage]) - MAX ([W1].[Percentage]) < 95;
	PRINT 'The top wait type since the cache was last cleared is "'+@WaitTypeAggregatedMain+'", having '+CONVERT(NVARCHAR(6),@WaitTypeAggregatedPercentage)+'% in total';

	PRINT ''; --Break

	-- ### SQL log severity 14,16,17,18,19,20,21,22,23,24,25 registry count
	DECLARE @ErrorLogSevCount INT;
	IF OBJECT_ID('tempdb..#errorlog_check') IS NOT NULL BEGIN DROP TABLE [#errorlog_check]; END; CREATE TABLE [#errorlog_check] ([LogDate] DATETIME,[ProcessInfo] VARCHAR(12),[Text] VARCHAR(MAX));
	SET @cmd='EXEC xp_readerrorlog 0,1,N''Severity: 1'',NULL,N'''+CONVERT(VARCHAR(28),DATEADD(hh,-4,GETDATE()),113)+''',N'''+CONVERT(VARCHAR(28),GETDATE(),113)+''''; INSERT INTO [#errorlog_check] EXEC (@cmd); 	SET @cmd='EXEC xp_readerrorlog 0,1,N''Severity: 2'',NULL,N'''+CONVERT(VARCHAR(28),DATEADD(hh,-4,GETDATE()),113)+''',N'''+CONVERT(VARCHAR(28),GETDATE(),113)+''''; INSERT INTO [#errorlog_check] EXEC (@cmd);
	SELECT @ErrorLogSevCount=COUNT([Text]) FROM [#errorlog_check] WHERE LEFT(RIGHT([Text],LEN([Text])-CHARINDEX('Severity',[Text])-9),2)>13 AND LEFT(RIGHT([Text],LEN([Text])-CHARINDEX('Severity',[Text])-9),2)<>15; DROP TABLE [#errorlog_check];
	IF @ErrorLogSevCount>0
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(8),@ErrorLogSevCount)+' non-informational severity errors registered on the current error log on the past 4 hours';
	END;
	ELSE IF @ErrorLogSevCount=0
	BEGIN
		PRINT 'No non-informational severity errors registered on the current error log on the past 4 hours';
	END;

	-- ### Databases configuration
	DECLARE @is_auto_close_on INT, @is_auto_shrink_on INT, @page_verify_option INT, @is_auto_update_stats_on INT, @is_auto_create_stats_on INT; SELECT @is_auto_close_on=SUM(CONVERT(INT,[is_auto_close_on])), @is_auto_shrink_on=SUM(CONVERT(INT,[is_auto_shrink_on])), @page_verify_option=SUM(CASE [page_verify_option] WHEN 0 THEN 1 WHEN 1 THEN 1 ELSE 0 END), @is_auto_update_stats_on=SUM(CASE [is_auto_update_stats_on] WHEN 1 THEN 0 WHEN 0 THEN 1 END), @is_auto_create_stats_on=SUM(CASE [is_auto_create_stats_on] WHEN 1 THEN 0 WHEN 0 THEN 1 END) FROM [master].[sys].[databases]; 
	IF (@is_auto_close_on+@is_auto_shrink_on+@is_auto_update_stats_on+@is_auto_create_stats_on)>0
	BEGIN
		PRINT '[!] Databases configured with auto-close '+CONVERT(NVARCHAR(8),@is_auto_close_on)+', auto-shrink '+CONVERT(NVARCHAR(8),@is_auto_shrink_on)+', no auto-create-stats '+CONVERT(NVARCHAR(8),@is_auto_create_stats_on)+', no auto-update-stats '+CONVERT(NVARCHAR(8),@is_auto_update_stats_on);
	END;

	-- ### Page verification other than CHECKSUM
	IF (@page_verify_option)>0
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(8),@page_verify_option)+' databases are configured with page verification other than CHECKSUM';
	END;

	-- ### Logs with high use
	DECLARE @LogsHighUse INT; SELECT @LogsHighUse=COUNT([cntr_value]) FROM [sys].[dm_os_performance_counters] WHERE [counter_name] ='Percent Log Used' AND [cntr_value]>80 AND [instance_name]<>'_Total';
	IF @LogsHighUse>0
	BEGIN
		IF @os_performance_counters<>0 BEGIN PRINT '[!] '+CONVERT(NVARCHAR(8),@LogsHighUse)+' transaction logs are currently used above 80% of their total size'; END;
	END;
	ELSE IF @LogsHighUse=0
	BEGIN
		PRINT 'All transaction logs are currently used below 80% of their total size';
	END;

	-- ### VLF count on all DBs
	DECLARE @DBs_High_VLfs INT, @TopDB_High_VLfs NVARCHAR(256), @TopDB_High_VLfs_Count INT, @DBName sysname, @VLfs INT; CREATE TABLE [#DatabasesVLFs] ([DBName] sysname); DECLARE @VLFCounts TABLE ([DBName] sysname,[VLFCount] INT); INSERT INTO [#DatabasesVLFs] SELECT [name] FROM [sys].[databases] WHERE [state]=0;
	IF LEFT(CAST(SERVERPROPERTY('PRODUCTVERSION') AS NVARCHAR(MAX)),CHARINDEX('.',CAST(SERVERPROPERTY('PRODUCTVERSION') AS NVARCHAR(MAX)))-1) < 11
	BEGIN
		DECLARE @DBCCLogInfo TABLE ([FileID] TINYINT, [File_Size] BIGINT, [Start_Offset] BIGINT,[FSeqNo] INT,[Status] TINYINT,[Parity] TINYINT,[Create_LSN] NUMERIC(25,0)); WHILE EXISTS(SELECT TOP 1 [DBName] FROM [#DatabasesVLFs]) BEGIN SET @DBName = (SELECT TOP 1 [DBName] FROM [#DatabasesVLFs]); SET @cmd = 'DBCC LOGINFO (' + '''' + @DBName + ''' ) WITH NO_INFOMSGS'; INSERT INTO @DBCCLogInfo EXEC (@cmd); SET @VLfs=@@ROWCOUNT; INSERT @VLFCounts VALUES(@DBName, @VLfs); DELETE FROM [#DatabasesVLFs] WHERE [DBName]=@DBName; END;
	END;
	ELSE BEGIN
	   DECLARE @DBCCLogInfo2012 TABLE ([RECOVERYUNITID] INT, [FileID] TINYINT, [File_Size] BIGINT, [Start_Offset] BIGINT, [FseqNo] INT, [STATUS] TINYINT, [Parity] TINYINT, [Create_LSN] NUMERIC(25,0)); WHILE EXISTS(SELECT TOP 1 [DBName] FROM [#DatabasesVLFs]) BEGIN SET @DBName = (SELECT TOP 1 [DBName] FROM [#DatabasesVLFs]); SET @cmd = 'DBCC LOGINFO (' + '''' + @DBName + ''' ) WITH NO_INFOMSGS'; INSERT INTO @DBCCLogInfo2012 EXEC (@cmd); SET @VLfs = @@ROWCOUNT;  INSERT @VLFCounts VALUES(@DBName, @VLfs); DELETE FROM [#DatabasesVLFs] WHERE [DBName] = @DBName; END;
	END;
	SELECT @DBs_High_VLfs=COUNT([VLFCount])FROM @VLFCounts WHERE [VLFCount]>300;
	IF @DBs_High_VLfs>1
	BEGIN
		SELECT TOP 1 @TopDB_High_VLfs_Count=[VLFCount], @TopDB_High_VLfs=[DBName] FROM @VLFCounts ORDER BY [VLFCount] DESC;
		PRINT '[!] '+CONVERT(NVARCHAR(28),@DBs_High_VLfs)+' transaction logs have more than 300 virtual log files, "'+@TopDB_High_VLfs+'" being top with '+CONVERT(NVARCHAR(28),@TopDB_High_VLfs_Count);
	END;
	DROP TABLE [#DatabasesVLFs];

	-- ### User databases recovery models
	DECLARE @recovery_simple INT, @recovery_bulked INT, @recovery_full INT; 
	SELECT @recovery_simple=SUM(CASE [recovery_model] WHEN 3 THEN 1 ELSE 0 END), @recovery_bulked=SUM(CASE [recovery_model] WHEN 2 THEN 1 ELSE 0 END), @recovery_full=SUM(CASE [recovery_model] WHEN 1 THEN 1 ELSE 0 END) FROM [master].[sys].[databases];
	BEGIN
		PRINT 'Databases'' recovery modes are'
		+' simple '+CONVERT(NVARCHAR(8),@recovery_simple)
		+', bulk-logged '+CONVERT(NVARCHAR(8),@recovery_bulked)
		+', full '+CONVERT(NVARCHAR(8),@recovery_full);
	END;

	-- ### Databases compatibility levels
	DECLARE @compatibility_level SMALLINT; SELECT @compatibility_level=ISNULL(COUNT([compatibility_level]),0) FROM [sys].[databases] WHERE LEFT([compatibility_level],2)<>SERVERPROPERTY('ProductMajorVersion');
	IF @compatibility_level>0 
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(32),@compatibility_level)+' databases are configured with a compatibility level different from the current engine''s version';
	END;
	
	-- ### Databases on the server without full backups on the last 7 days
	DECLARE @DBsNoFullBkps7Days INT; 
	SELECT DISTINCT [database_name] INTO [#backups_full_7days] FROM [msdb].[dbo].[backupmediafamily] INNER JOIN [msdb].[dbo].[backupset] ON [backupmediafamily].[media_set_id] = [backupset].[media_set_id] WHERE  DATEDIFF(dd, [backup_start_date],GETDATE())<7 AND [msdb]..[backupset].[type] ='D';
	SELECT @DBsNoFullBkps7Days=SUM(CASE WHEN [bkps].[database_name] IS NULL THEN 1 ELSE 0 END) FROM [master].[sys].[databases] [dbs] LEFT JOIN [#backups_full_7days] [bkps] ON [dbs].[name]=[bkps].[database_name] WHERE [dbs].[name] NOT IN ('tempdb','mssqlsystemresource'); DROP TABLE [#backups_full_7days];
	IF @DBsNoFullBkps7Days>0
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(8),@DBsNoFullBkps7Days)+' databases have NOT had a full backup within the last 7 days';
	END;
	ELSE IF @DBsNoFullBkps7Days=0
	BEGIN
		PRINT 'All the databases on the server have had a full backup within the last 7 days';
	END;

	-- ### Databases on the server without an integrity check on the last 7 days
	/* Credit for this block to Ryan DeVries http://ryandevries.com/ */ 
	DECLARE @DBsNoIntegrityChk INT; SET @DBsNoIntegrityChk=0; CREATE TABLE [#DBInfo] ([ParentObject] VARCHAR(255), [Object] VARCHAR(255), [Field] VARCHAR(255), [Value] VARCHAR(255)); CREATE TABLE [#Value] ([DatabaseName] VARCHAR(255), [LastDBCCCheckDB] DATETIME);
	EXECUTE [sys].[sp_MSforeachdb] 'INSERT INTO #DBInfo EXECUTE (''DBCC DBINFO ( ''''?'''' ) WITH TABLERESULTS, NO_INFOMSGS''); INSERT INTO #Value (DatabaseName, LastDBCCCheckDB) (SELECT ''?'', [Value] FROM #DBInfo WHERE Field = ''dbi_dbccLastKnownGood''); TRUNCATE TABLE #DBInfo;';
	DELETE FROM [#Value] WHERE DATEDIFF(dd,[LastDBCCCheckDB],GETDATE())>15; ;WITH [cte] AS (SELECT ROW_NUMBER() OVER (PARTITION BY [DatabaseName] ORDER BY [LastDBCCCheckDB] DESC) [RN] FROM [#Value]) DELETE FROM [cte] WHERE  [cte].[RN] > 1;
	SELECT @DBsNoIntegrityChk=SUM(CASE WHEN [DatabaseName] IS NULL THEN 1 ELSE 0 END) FROM [master].[sys].[databases] [db] LEFT JOIN [#Value] ON [db].[name]=[DatabaseName]; DROP TABLE [#Value]; DROP TABLE [#DBInfo];
	IF @DBsNoIntegrityChk>0 
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(8),@DBsNoIntegrityChk)+' databases have NOT had an integrity check within the last 15 days';
	END;
	ELSE IF @DBsNoIntegrityChk=0
	BEGIN
		PRINT 'All the databases on the server have had an intregrity check within the last 15 days';
	END;

	-- ### Check for existing suspect_pages within the last 15 days
	/* Feedback from David Klee */
	DECLARE @suspect_pages SMALLINT; SELECT @suspect_pages=ISNULL(COUNT(*),0) FROM [msdb].[dbo].[suspect_pages] WHERE [last_update_date]>=(GETDATE()-15);
	IF @suspect_pages>0 
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(32),@suspect_pages)+' pages have been found marked as curruption-suspect on [msdb].[dbo].[suspect_pages] within the last 15 days';
	END;
	-- ### Check for unsent mail items within the last 7 days
	DECLARE @unsent_mail SMALLINT; SELECT @unsent_mail=ISNULL(COUNT(*),0) FROM [msdb].[dbo].[sysmail_unsentitems] WHERE [sent_date]>=(GETDATE()-7);
	IF @unsent_mail>0 
	BEGIN
		PRINT '[!] '+CONVERT(NVARCHAR(32),@unsent_mail)+' unsent queued database emails have been found within the last 7 days';
	END;


--===============================================================================================================================--
--===================================================== MIRRORING STATUS ========================================================--
--===============================================================================================================================--

	-- ### Check database mirroring status
	IF (@mirror_COUNT>0) 
	BEGIN 
		IF (@mirror_COUNT = @mirrorCOUNTsynch) 
			BEGIN 
				PRINT 'All '+CONVERT(NVARCHAR(3),@mirror_COUNT)+' databases configured with mirroring are in sync status'; 
			END;
		ELSE 
			BEGIN 
				PRINT '[!] '+CONVERT(NVARCHAR(3),(@mirror_COUNT-@mirrorCOUNTsynch))+' databases configured with mirroring are NOT in sync status';
			END; 

	-- ### Database mirroring performance stats
		DECLARE  @Mirroring_BytesSent_sec BIGINT ,@Mirroring_BytesReceived_sec BIGINT ,@Mirroring_Mirrored_WriteTransactions_sec BIGINT ,@Mirroring_Transaction_Delay BIGINT ,@Mirroring_LogSendQueueKB BIGINT;

		;WITH [perfmon_results_mirroring] AS
		(SELECT [perfmon_results_t_m].[counter_name], [perfmon_results_t_m].[cntr_value] FROM 
			(	SELECT [perfmon_diff_mirroring].[counter_name], ( CONVERT(DECIMAL(32,2),([perfmon_diff_mirroring].[cntr_value])-CONVERT(DECIMAL(32,2),[perfmon_baseline_m].[cntr_value])) / (DATEDIFF(MILLISECOND,@start_time,GETDATE())/1000) ) [cntr_value]
				FROM [sys].[dm_os_performance_counters] [perfmon_diff_mirroring]
				INNER JOIN [#perfmon_baseline_mirroring] [perfmon_baseline_m] ON [perfmon_baseline_m].[counter_name] = [perfmon_diff_mirroring].[counter_name]
				WHERE	[perfmon_diff_mirroring].[object_name]='SQLServer:Database Mirroring'
						AND ([perfmon_diff_mirroring].[counter_name] IN ('Bytes Sent/sec' ,'Bytes Received/sec' ,'Mirrored Write Transactions/sec' ,'Transaction Delay')
							 AND [perfmon_diff_mirroring].[instance_name]='_Total'
							 )
			) [perfmon_results_t_m]
		)
		SELECT	 @Mirroring_BytesSent_sec=ISNULL((SELECT [perfmon_results_mirroring].[cntr_value] FROM [perfmon_results_mirroring] WHERE [perfmon_results_mirroring].[counter_name]='Bytes Sent/sec'),0)
				,@Mirroring_BytesReceived_sec=ISNULL((SELECT [perfmon_results_mirroring].[cntr_value] FROM [perfmon_results_mirroring] WHERE [perfmon_results_mirroring].[counter_name]='Bytes Received/sec'),0)
				,@Mirroring_Mirrored_WriteTransactions_sec=ISNULL((SELECT [perfmon_results_mirroring].[cntr_value] FROM [perfmon_results_mirroring] WHERE [perfmon_results_mirroring].[counter_name]='Mirrored Write Transactions/sec'),0)
				,@Mirroring_Transaction_Delay=ISNULL((SELECT [perfmon_results_mirroring].[cntr_value] FROM [perfmon_results_mirroring] WHERE [perfmon_results_mirroring].[counter_name]='Transaction Delay'),0)
				,@Mirroring_LogSendQueueKB=ISNULL((SELECT [cntr_value] FROM [sys].[dm_os_performance_counters] WHERE [object_name]='SQLServer:Database Mirroring' AND [instance_name]='_Total' AND [counter_name]='Log Send Queue KB'),0);

		IF OBJECT_ID('tempdb..#perfmon_baseline_mirroring') IS NOT NULL BEGIN DROP TABLE [#perfmon_baseline_mirroring]; END;

		PRINT CONVERT(NVARCHAR(8),@Mirroring_Mirrored_WriteTransactions_sec)+' mirrored transactions, sending '+CONVERT(NVARCHAR(8),( @Mirroring_BytesSent_sec/1024) )+ ' KB and receiving '+CONVERT(NVARCHAR(8),(@Mirroring_BytesReceived_sec/1024) )+' KB per second with '+CONVERT(NVARCHAR(8),@Mirroring_Transaction_Delay)+' ms latency, '+CONVERT(NVARCHAR(8),@Mirroring_LogSendQueueKB)+' KB unsent';

	END;

	-- ### Has there been any page autorepair?
	IF (CONVERT(INT ,@@microsoftversion)>=171051460) --SQL2008R2SP1 or greater
	 BEGIN
		  DECLARE @mirroring_auto_page_repair INT; SELECT @mirroring_auto_page_repair=COUNT([file_id]) FROM [sys].[dm_db_mirroring_auto_page_repair];
		  IF (@mirroring_auto_page_repair>0)
		  BEGIN 
			   PRINT '[!] Mirroring auto page repair has taken place '+CONVERT(NVARCHAR(4) ,@mirroring_auto_page_repair)+' times';
		  END;
	END;


--===============================================================================================================================--
--======================================================= REPLICATION ===========================================================--
--===============================================================================================================================--

	-- ### Replication
	IF (SELECT SUM(CONVERT(INT,[is_published]))+SUM(CONVERT(INT,[is_subscribed])) FROM [sys].[databases] WHERE [is_published]=1 OR [is_subscribed]=1)>1
	BEGIN
		DECLARE @ReplIsPublished INT, @ReplIsSubscribed INT, @ReplIsDistributor INT;
		SELECT @ReplIsPublished=SUM(CONVERT(INT,[is_published])), @ReplIsSubscribed=SUM(CONVERT(INT,[is_subscribed])), @ReplIsDistributor=SUM(CONVERT(INT,[is_distributor])) FROM [sys].[databases];
		DECLARE @ReplPendingXacts INT; SELECT @ReplPendingXacts=(SELECT SUM([cntr_value]) FROM [sys].[dm_os_performance_counters] WHERE [object_name]='SQLServer:Databases' AND [counter_name]='Repl. Pending Xacts' AND [instance_name] IN ('_Total')) - (SELECT SUM([cntr_value]) FROM [sys].[dm_os_performance_counters] WHERE [object_name]='SQLServer:Databases' AND [counter_name]='Repl. Pending Xacts' AND [instance_name] IN ('master','model','tempdb','msdb'));

		IF @os_performance_counters<>0 BEGIN PRINT 'Replication is enabled with databases published '+CONVERT(NVARCHAR(64),@ReplIsPublished)+', subscribed '+CONVERT(NVARCHAR(64),@ReplIsSubscribed)+', distributor '+CONVERT(NVARCHAR(64),@ReplIsDistributor)+' having '+CONVERT(NVARCHAR(64),@ReplPendingXacts)+' transactions to be published'; END;
	END;

	-- ### Footer print
	PRINT CHAR(10)+'/* [sp_health_check] by @sqlslancaster - find help at http://sqlhealthcheck.net/how-to */';

GO

