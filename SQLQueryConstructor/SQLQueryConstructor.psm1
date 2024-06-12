function sql
{ 
	param(
	$query
	)
	return Invoke-Sqlcmd -ServerInstance $serverInfo.ServerInstance -Database $serverInfo.Database -TrustServerCertificate -Query $query
}

function Get-AGColumnNames
{
    param(
        $tableName,
        $dbName,
        $lite
    )
    #sample for manually defining column names/primary key names
    <#
    if($tableName.tolower() -eq "sample")
    {
        $columnNames = @("Col1", "Col2")
        $primaryKeys = @("Col1", "Col2")
    elseif($tableName.tolower() -eq "sample2")
    {
        $columnNames = @("Col1", "Col2")
        $primaryKeys = @("Col1", "Col2")
    }
    #$primaryKeys = '@("' + ($primaryKeys -join '", "') + '")'
    #$columnNames = '@("' + ($columnNames -join '", "') + '")'#>
    if($lite)
    {
       #can't do "SELECT * FROM pragma_table-info" for some reason
       $columnNames = (Invoke-SqliteQuery -DataSource $dbName -Query "PRAGMA table_info($tableName)").Name
       $primaryKeys = (Invoke-SqliteQuery -DataSource $dbName -Query "PRAGMA table_info($tableName)" | Where-Object {$_.pk -ne 0}).Name
    }
    else
    {
        $columnNames = (sql -query ("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '" + $tableName + "'")).COLUMN_NAME
        $primaryKeys = (sql -query ("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE WHERE TABLE_NAME = '" + $tableName + "'")).COLUMN_NAME

    }
    $returnValue = @{}
    $returnValue["columnNames"] = $columnNames
    $returnValue["primaryKeys"] = $primaryKeys
    return $returnValue
}

function Get-AGIfNotExistsStatement
{
    param(
        $valueHash,
        $primaryKeys,
        $tableName
    )
    $ifStatement = "IF NOT EXISTS(SELECT * FROM $tableName WHERE "
    $firstColumn = $true
    foreach($name in $primaryKeys)
    {
        if(!$firstColumn)
        {
            $ifStatement += 'AND '
        }
        else
        {
            $firstColumn = $false
        }
        $ifStatement += "$name = '" + $valueHash[$name] + "' " 
    }
    $ifStatement += ")
    "
    return $ifStatement
}

function Get-AGInsertStatementBuilder
{
    param(
        $valueHash,
        $tableName,
        $dbPath,
        $lite
    )
    #used if there's 1 data source being split over 2 or more tables
    $found = $false

    $c = Get-AGColumnNames -tableName $tableName -dbName $dbPath -lite $lite
    $columnNames = $c.columnNames
    $primaryKeys = $c.primaryKeys

    $properties = @{
        columns="("
        values="("
        insert = ""
        rawInsert = ""
        valueHash = @{}
    }

    $returnValue = New-Object pscustomobject -Property $properties
    $firstColumn = $true
    foreach($name in $columnNames)
    {
        #write-host $key " " $name
        if(!$firstColumn)
        {
            $returnValue.columns += ', '
            $returnValue.values += ", '"
        }
        else
        {
            #$returnValue.columns += '"'
            $returnValue.values += "'"
            $firstColumn = $false
        }
        $returnValue.columns += $name #+ '"'
        $returnValue.values += [String]$valueHash[$name] + "'"
    }
    #get primary key values
    $ifElseStatement = ""
    #
    $ifStatement = Get-AGIfNotExistsStatement -valueHash $valueHash -primaryKeys $primaryKeys -tableName $tableName
    #
    $beginStatement = "
    BEGIN 
    "
    #
    $insertStatement = "INSERT INTO $tableName " + $returnValue.columns + ") VALUES " + $returnValue.values + ")"
    $returnValue.rawInsert = $insertStatement
    #
    $ifElse = $ifStatement + $beginStatement + $insertStatement + "
    END"
    $returnValue.insert = $ifElse
    return $returnValue
}

function get-agUpdateStatementBuilder
{
    param(
        $dbPath,
        $lite,
        $valueHash,
        $tableName,
        $existsConditional# = "AND (TicketNumber = '' OR TicketNumber IS NULL) AND (poRequester = 'notfound' OR poRequester = '' OR poRequester IS NULL)"
    )
    $c = Get-AGColumnNames -tableName $tableName -dbName $dbPath -lite $lite
    $columnNames = $c.columnNames
    $primaryKeys = $c.primaryKeys
    $properties = @{
        update = ""
        rawUpdate = ""
        valueHash = @{}
    }
    $returnValue = New-Object pscustomobject -Property $properties
    $returnValue.update = "UPDATE $tableName SET "
    $whereClause = " WHERE "
    $firstNonPKColumn = $true
    $firstPKColumn = $true
    foreach($key in $valueHash.keys)
    {
        $PK = $false
        foreach($name in $primaryKeys)
        {
            if($name -eq $key)
            {
                $pk = $true
                if(!$firstPKColumn)
                {
                    $whereClause += 'AND '
                }
                else
                {
                    $firstPKColumn = $false
                }
                $whereClause += "$name = '" + $valueHash[$name] + "' "
                break
            }
        }
        if(!$pk)
        {
            foreach($name in $columnNames)
            {
                if($name -eq $key)
                {
                    if(!$firstNonPKColumn)
                    {
                        $returnValue.update += ', '
                    }
                    else
                    {
                        $firstNonPKColumn = $false
                    }
                    $returnValue.update += "$name='" + $valueHash[$name] + "'"
                }
            }
        }
    }
    $returnValue.update += $whereClause + $existsConditional
    $returnValue.rawUpdate = $returnValue.update
    $insert = Get-AGInsertStatementBuilder -valueHash $valueHash -tableName $tableName -dbPath $dbPath -lite $lite
    $insertStatement = "INSERT INTO $tableName " + $insert.columns + ") VALUES " + $insert.values + ")"

    $ifElseStatement = ""
    #
    $ifStatement = Get-AGIfNotExistsStatement -valueHash $valueHash -primaryKeys $primaryKeys -tableName $tableName
    #
    $beginStatement = "BEGIN
    $insertStatement       
    END
    ELSE
    BEGIN
    "
    #
    $ifElse = $ifStatement + $beginStatement + $returnValue.update + "
    END"
    $returnValue.update = $ifElse
    return $returnValue
}

function Get-AGSqliteTableConnection
{
    param(
        $databasePath,
        $databaseTable,
	    [switch]$help
    )
    if($help)
    {
	    write-host
	    "validates that the SQLite file and specified table exist. Returns true or false and writes a message to the console. 
    arguments:
	    -databasePath: takes full path to sqlite file.
	    -databaseTable: takes table name
	    "
	    break
    }
    if(!(Test-Path $databasePath))
    {
        write-host "Can't find (or don't have access to) $databasePath"
        return $false
    }
    else
    {
        write-host "Found $databasePath"
        $error.clear()
        try
        {
            $tableTest = Invoke-SqliteQuery -datasource $databasePath "SELECT * FROM sqlite_master WHERE type='table' AND name='$databaseTable'"
        }
        catch
        {
            $e = $error
        }
        if($e)
        {
            Write-Host "$databasePath is an invalid sqlite file"
            return $false
        }
        elseif($tableTest -eq $null)
        {
            write-host "No such table $databaseTable. Tables on this db are"
            $t = Invoke-SqliteQuery -datasource $databasePath "SELECT table FROM sqlite_master WHERE type='table' AND name='$databaseTable'"
            Write-Host $t
            return $false
        }
        Write-Host "Validated $databaseTable exists"
        return $true
    }
}
$modulePath = (Get-Module -ListAvailable SQLQueryConstructor).path
$serverInfo =  import-csv ($modulePath.Substring(0,$modulePath.LastIndexOf("\")) + "\Config\serverInfo.csv")

$e = $Global:error.count
Import-Module SqlServer
if($e -lt $Global:error.Count)
{
    write-host "WARNING: missing SqlServer module (used with t-sql)" -BackgroundColor Yellow -ForegroundColor Black 
}
$e = $Global:error.count
Import-Module PSSQLite
if($e -lt $Global:error.Count)
{
    write-host "WARNING: missing PSSQLite module (used with sqlite)" -BackgroundColor Yellow -ForegroundColor Black 
}
