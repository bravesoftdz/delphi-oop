unit CouchDBTest;

interface

{
  In order to use these unit tests CouchDB (http://couchdb.apache.org/) must be installed on local PC.
}

uses
  TestFramework
  ,SvHTTPClientInterface
  ,SvRest.Client
  ,SvHTTP.Attributes
  ;

type
  TCouchPerson = class
  private
    FName: string;
    FId: Integer;
    FLastEdited: TDateTime;
  public
    property Name: string read FName write FName;
    property LastEdited: TDateTime read FLastEdited write FLastEdited;
    property MyId: Integer read FId write FId;
  end;

  TCouchDBInfo = class
  private
    Fdb_name: string;
    Fdisk_size: Int64;
    Fdoc_count: Int64;
  public
    property db_name: string read Fdb_name write Fdb_name;
    property disk_size: Int64 read Fdisk_size write Fdisk_size;
    property doc_count: Int64 read Fdoc_count write Fdoc_count;

  end;

  TCouchAddResponse = class

  end;

  TCouchDBResponse = class
  private
    Frev: string;
    Fok: Boolean;
    Fid: string;
  public
    property ok: Boolean read Fok write Fok;
    property id: string read Fid write Fid;
    property rev: string read Frev write Frev;
  end;

  TCouchDBClient = class(TSvRESTClient)
  public
    [POST]
    [Path('/unittest')]
    [Consumes(MEDIA_TYPE.JSON)]
    [Produces(MEDIA_TYPE.JSON)]
    {$WARNINGS OFF}
    function AddPerson([BodyParam] APerson: TCouchPerson; [HeaderParam] Foobar: string): TCouchDBResponse; virtual;

    [GET]
    [Path('/unittest/{AId}')]
    [Consumes(MEDIA_TYPE.JSON)]
    [Produces(MEDIA_TYPE.JSON)]
    function GetPerson([QueryParam] const AId: string): TCouchPerson; virtual;

    [GET]
    [Path('/unittest/{AId}')]
    [Consumes(MEDIA_TYPE.JSON)]
    [Produces(MEDIA_TYPE.JSON)]
    function GetPersonAsJsonString([QueryParam] const AId: string): string; virtual;

    [Path('/unittest/')]
    [Consumes(MEDIA_TYPE.JSON)]
    [PUT]
    function CreateDatabase(): TCouchDBResponse; virtual;

    [Path('/unittest/')]
    [Consumes(MEDIA_TYPE.JSON)]
    [DELETE]
    function DeleteDatabase(): TCouchDBResponse; virtual;

    [Path('/unittest')]
    [Consumes(MEDIA_TYPE.JSON)]
    [Produces(MEDIA_TYPE.JSON)]
    [GET]
    function GetDBInfo(): TCouchDBInfo; virtual;

    {$WARNINGS ON}
  end;


  TCouchDBTest = class(TTestCase)
  private
    FClient: TCouchDBClient;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  protected
    procedure CreateDatabase();
    procedure DeleteDatabase();
  published
    procedure Add_Get_Document();
  end;

implementation

uses
  SvWeb.Consts
  ,SysUtils
  ,StrUtils
  ,IdHTTP
  ,WinSock
  ;

{ TCouchDBTest }

procedure TCouchDBTest.Add_Get_Document;
var
  LResp: TCouchDBResponse;
  LPerson, LNewPerson: TCouchPerson;
  LJson: string;
begin
  LPerson := TCouchPerson.Create;
  try
    LPerson.Name := 'FooBar';
    LPerson.LastEdited := Now;
    LPerson.MyId := 1;
    LResp := FClient.AddPerson(LPerson, 'Header Param');
    try
      CheckTrue(LResp.ok);

      LNewPerson := FClient.GetPerson(LResp.id);
      try
        CheckEquals(LPerson.Name, LNewPerson.Name);
        CheckEquals(LPerson.MyId, LNewPerson.MyId);
      finally
        LNewPerson.Free;
      end;

      LJson := Trim(FClient.GetPersonAsJsonString(LResp.id));
      CheckTrue(LJson <> '');
      CheckTrue(StartsStr('{', LJson));
      CheckTrue(EndsStr('}', LJson));
      Status(LJson);

    finally
      LResp.Free;
    end;
  finally
    LPerson.Free;
  end;
end;

procedure TCouchDBTest.CreateDatabase;
var
  LResp: TCouchDBResponse;
  LDBInfo: TCouchDBInfo;
begin
  try
    LResp := FClient.CreateDatabase;
    try
      CheckTrue(LResp.ok);
    finally
      LResp.Free;
    end;
  except
    //eat
  end;

  LDBInfo := FClient.GetDBInfo();
  try
    CheckEquals('unittest', LDBInfo.db_name);
  finally
    LDBInfo.Free;
  end;
end;

procedure TCouchDBTest.DeleteDatabase;
var
  LDBInfo: TCouchDBInfo;
begin
  try
    LDBInfo := FClient.GetDBInfo();
    try
      if SameText('unittest', LDBInfo.db_name) then
      begin
        FClient.DeleteDatabase();
      end;
    finally
      LDBInfo.Free;
    end;
  except

  end;
end;

procedure TCouchDBTest.Setup;
begin
  inherited;
  FClient := TCouchDBClient.Create('http://127.0.0.1:5984');
  FClient.SetHttpClient(HTTP_CLIENT_INDY);
  CreateDatabase();
end;

procedure TCouchDBTest.TearDown;
begin
  inherited;
  DeleteDatabase();
  FClient.Free;
end;

 {$WARNINGS OFF}

{ TCouchDBClient }

function TCouchDBClient.AddPerson(APerson: TCouchPerson; Foobar: string): TCouchDBResponse;
begin

end;

function TCouchDBClient.CreateDatabase: TCouchDBResponse;
begin

end;

function TCouchDBClient.DeleteDatabase: TCouchDBResponse;
begin

end;

function TCouchDBClient.GetDBInfo: TCouchDBInfo;
begin

end;

function TCouchDBClient.GetPerson(const AId: string): TCouchPerson;
begin

end;

function TCouchDBClient.GetPersonAsJsonString(const AId: string): string;
begin

end;

{$WARNINGS ON}

function PortTCP_IsOpen(dwPort : Word; ipAddressStr:AnsiString) : boolean;
var
  client : sockaddr_in;
  sock   : Integer;
  ret    : Integer;
  wsdata : WSAData;
begin
  Result:=False;
  ret := WSAStartup($0002, wsdata); //initiates use of the Winsock DLL
  if ret<>0 then exit;
  try
    client.sin_family      := AF_INET;  //Set the protocol to use , in this case (IPv4)
    client.sin_port        := htons(dwPort); //convert to TCP/IP network byte order (big-endian)
    client.sin_addr.s_addr := inet_addr(PAnsiChar(ipAddressStr));  //convert to IN_ADDR  structure
    sock  :=socket(AF_INET, SOCK_STREAM, 0);    //creates a socket
    Result:=connect(sock,client,SizeOf(client))=0;  //establishes a connection to a specified socket
  finally
    WSACleanup;
  end;
end;

function CouchDBInstalled(): Boolean;
begin
  Result := PortTCP_IsOpen(5984, '127.0.0.1');
end;

initialization
  if CouchDBInstalled then
    RegisterTest(TCouchDBTest.Suite);

end.
