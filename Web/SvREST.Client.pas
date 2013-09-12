unit SvREST.Client;

interface

uses
  Rtti
  ,SvHTTPClientInterface
  ,SvREST.Method
  ,SvWeb.Consts
  ,SvVMI
  ,Generics.Collections
  ,Classes
  ,TypInfo
  ;

type
  TRESTClient = class(TInterfacedObject)
  private
    FCtx: TRttiContext;
    FURL: string;
    FVMI: TSvVirtualMethodInterceptor;
    FHttp: IHTTPClient;
    FMethods: TObjectDictionary<Pointer,TRESTMethod>;
    FProxyObject: TObject;
    FProxyTypeInfo: PTypeInfo;
    FDoInvokeMethods: Boolean;
    FAuthentication: IHttpAuthentication;
    FEncodeParameters: Boolean;
  protected
    procedure DoOnAfter(Instance: TObject; Method: TRttiMethod;
      const Args: TArray<TValue>; var Result: TValue);
    procedure DoRequest(Method: TRttiMethod; const Args: TArray<TValue>; ARestMethod: TRESTMethod;
      var Result: TValue); virtual;
    procedure DoGetRequest(Method: TRttiMethod; const Args: TArray<TValue>; ARestMethod: TRESTMethod;
      var Result: TValue); virtual;
    procedure DoPostRequest(Method: TRttiMethod; const Args: TArray<TValue>; ARestMethod: TRESTMethod;
      var Result: TValue); virtual;
    procedure DoPutRequest(Method: TRttiMethod; const Args: TArray<TValue>; ARestMethod: TRESTMethod;
      var Result: TValue); virtual;
    procedure DoDeleteRequest(ARestMethod: TRESTMethod; var Result: TValue); virtual;
    function IsMethodMarked(AMethod: TRttiMethod): Boolean;
    function GetRESTMethod(AMethod: TRttiMethod; AType: TRttiType): TRESTMethod;
    function GetRequestType(AMethod: TRttiMethod): TRequestType;
    procedure EnumerateRESTMethods();
    function GenerateUrl(ARestMethod: TRESTMethod): string; virtual;
    function DoCheckPathParameters(const AUrl: string; ARestMethod: TRESTMethod): string;
    function GenerateSourceContent(ARestMethod: TRESTMethod): TStream;
    function GetSerializedDataString(const AValue: TValue; ARestMethod: TRESTMethod): string;
    function SerializeObjectToString(AObject: TObject; ARestMethod: TRESTMethod): string;
    procedure FillRestMethodParameters(const Args: TArray<TValue>; ARestMethod: TRESTMethod; AMethod: TRttiMethod);
    function ConsumeMediaType(ARttiType: TRttiType; const ASource: TValue; ARestMethod: TRESTMethod): TValue; virtual;
    function ConsumeMediaTypeAsString(ARttiType: TRttiType; const ASource: TValue; ARestMethod: TRESTMethod): string; virtual;
    function UrlEncode(const S: string): string; virtual;
    function UrlEncodeRFC3986(const URL: string): string; virtual;
    function HasAuthentication(): Boolean; virtual;
  public
    constructor Create(const AUrl: string; AProxyObject: TObject = nil; AProxyType: PTypeInfo = nil); virtual;
    destructor Destroy; override;

    procedure SetHttpClient(const AHttpClientName: string = HTTP_CLIENT_INDY);

    function IsHttps(): Boolean;

    property Authentication: IHttpAuthentication read FAuthentication write FAuthentication;
    property EncodeParameters: Boolean read FEncodeParameters write FEncodeParameters;
    property DoInvokeMethods: Boolean read FDoInvokeMethods write FDoInvokeMethods;
    property HttpClient: IHTTPClient read FHttp write FHttp;
    property Url: string read FURL;
  end;

implementation

uses
  SvSerializer
  ,SvSerializerSuperJson
  ,SvSerializerNativeXML
  ,SysUtils
  ,SysConst
  ,StrUtils
  ,SvHTTPClient.Factory
  ,SvHTTP.Attributes
  ;

{ TRESTClient }

function TRESTClient.ConsumeMediaType(ARttiType: TRttiType; const ASource: TValue; ARestMethod: TRESTMethod): TValue;
begin
  Result := TValue.Empty;
  if ARttiType <> nil then
  begin
    if ARttiType.IsInstance then
    begin
      Result := ARttiType.AsInstance.MetaclassType.Create;
      case ARestMethod.ConsumeMediaType of
        MEDIA_TYPE.JSON: TSvSerializer.DeSerializeObject(Result.AsObject, GetSerializedDataString(ASource, ARestMethod), sstSuperJson);
        MEDIA_TYPE.XML: TSvSerializer.DeSerializeObject(Result.AsObject, GetSerializedDataString(ASource, ARestMethod), sstNativeXML);
      end;
    end
    else
      Result := ASource.ToString;
  end;
end;

function TRESTClient.ConsumeMediaTypeAsString(ARttiType: TRttiType; const ASource: TValue;
  ARestMethod: TRESTMethod): string;
begin
  Result := '';
  if ARttiType <> nil then
  begin
    if ARttiType.IsInstance then
    begin
      Result := GetSerializedDataString(ASource, ARestMethod);
    end
    else
      Result := ASource.ToString;
  end;
end;

constructor TRESTClient.Create(const AUrl: string; AProxyObject: TObject = nil; AProxyType: PTypeInfo = nil);
begin
  inherited Create();
  FProxyObject := AProxyObject;
  if FProxyObject = nil then
    FProxyObject := Self;

  FProxyTypeInfo := AProxyType;
  if FProxyTypeInfo = nil then
    FProxyTypeInfo := Self.ClassInfo;

  FCtx := TRttiContext.Create;
  FURL := AUrl;
  FHttp := nil;
  FVMI := TSvVirtualMethodInterceptor.Create(FProxyObject.ClassType);
  FMethods := TObjectDictionary<Pointer,TRESTMethod>.Create([doOwnsValues]);

  FVMI.OnBefore := procedure(Instance: TObject;
    Method: TRttiMethod; const Args: TArray<TValue>; out DoInvoke: Boolean;
    out Result: TValue)
    begin
      DoInvoke := FDoInvokeMethods;
      DoOnAfter(Instance, Method, Args, Result);
    end;

 { FVMI.OnAfter := procedure(Instance: TObject;
    Method: TRttiMethod; const Args: TArray<TValue>; var Result: TValue)
    begin
      DoOnAfter(Instance, Method, Args, Result);
    end;}

  EnumerateRESTMethods();
  FVMI.Proxify(FProxyObject);
end;

destructor TRESTClient.Destroy;
begin
  FMethods.Free;
  FVMI.Unproxify(FProxyObject);
  FVMI.Free;
  inherited Destroy;
end;

function TRESTClient.DoCheckPathParameters(const AUrl: string; ARestMethod: TRESTMethod): string;
var
  i: Integer;
  LPosTokenStart, LPosTokenEnd: Integer;
  LParsedParamName: string;
begin
  Result := AUrl;
  LPosTokenEnd := 0;
  LPosTokenStart := PosEx('{', Result);
  if LPosTokenStart > 0 then
    LPosTokenEnd := PosEx('}', Result, LPosTokenStart);
  while (LPosTokenStart > 0) and (LPosTokenEnd > LPosTokenStart) do
  begin
    LParsedParamName := Copy(Result, LPosTokenStart + 1, LPosTokenEnd - LPosTokenStart - 1);
    //search for this parameter
    for i := ARestMethod.Parameters.Count - 1 downto 0 do
    begin
      if SameText(LParsedParamName, ARestMethod.Parameters[i].Name) then
      begin
        //inject parameter value into query
        Result := ReplaceStr(Result, '{' + LParsedParamName + '}', ARestMethod.Parameters[i].ToString);
        ARestMethod.Parameters.Delete(i);
        Break;
      end;
    end;
    LPosTokenStart := PosEx('{', Result);
      if LPosTokenStart > 0 then
        LPosTokenEnd := PosEx('}', Result, LPosTokenStart);
  end;
end;

procedure TRESTClient.DoDeleteRequest(ARestMethod: TRESTMethod; var Result: TValue);
begin
  Result := FHttp.Delete(ARestMethod.Url);
end;

procedure TRESTClient.DoGetRequest(Method: TRttiMethod; const Args: TArray<TValue>;
  ARestMethod: TRESTMethod; var Result: TValue);
var
  LResponse: TStringStream;
begin
  LResponse := TStringStream.Create;
  try
    if (FHttp.Get(ARestMethod.Url, LResponse) = HTTP_RESPONSE_OK)  then
    begin
      if LResponse.Size > 0 then
      begin
        Result := ConsumeMediaType(Method.ReturnType, LResponse, ARestMethod);
      end;
    end;
  finally
    LResponse.Free;
  end;
end;

procedure TRESTClient.DoOnAfter(Instance: TObject; Method: TRttiMethod; const Args: TArray<TValue>;
  var Result: TValue);
var
  LMethod: TRESTMethod;
begin
  if not FMethods.TryGetValue(Method.Handle, LMethod) then
    Exit;

  DoRequest(Method, Args, LMethod, Result);
end;

procedure TRESTClient.DoPostRequest(Method: TRttiMethod; const Args: TArray<TValue>;
  ARestMethod: TRESTMethod; var Result: TValue);
var
  LResponse: TStringStream;
  LSourceContent: TStream;
begin
  LResponse := TStringStream.Create;
  LSourceContent := GenerateSourceContent(ARestMethod);
  try
    if (FHttp.Post(ARestMethod.Url, LResponse, LSourceContent) = HTTP_RESPONSE_OK) then
    begin
      if LResponse.Size > 0 then
      begin
        Result := ConsumeMediaType(Method.ReturnType, LResponse, ARestMethod);
      end;
    end;
  finally
    LSourceContent.Free;
    LResponse.Free;
  end;
end;

procedure TRESTClient.DoPutRequest(Method: TRttiMethod;
  const Args: TArray<TValue>; ARestMethod: TRESTMethod; var Result: TValue);
var
  LResponse: TStringStream;
  LSourceContent: TStream;
begin
  LResponse := TStringStream.Create;
  LSourceContent := GenerateSourceContent(ARestMethod);
  try
    if (FHttp.Put(ARestMethod.Url, LResponse, LSourceContent) = HTTP_RESPONSE_OK) then
    begin
      if LResponse.Size > 0 then
      begin
        Result := ConsumeMediaType(Method.ReturnType, LResponse, ARestMethod);
      end;
    end;
  finally
    LSourceContent.Free;
    LResponse.Free;
  end;
end;

procedure TRESTClient.DoRequest(Method: TRttiMethod; const Args: TArray<TValue>; ARestMethod: TRESTMethod;
  var Result: TValue);
begin
  FillRestMethodParameters(Args, ARestMethod, Method);
  FHttp.ConsumeMediaType := ARestMethod.ConsumeMediaType;
  FHttp.ProduceMediaType := ARestMethod.ProduceMediaType;

  if HasAuthentication then
  begin
    FHttp.ClearCustomRequestHeaders();
    FHttp.AddCustomRequestHeader(FAuthentication.GetCustomRequestHeader);
  end;

  ARestMethod.Url := GenerateUrl(ARestMethod);

  case ARestMethod.RequestType of
    rtGet: DoGetRequest(Method, Args, ARestMethod, Result);
    rtPost: DoPostRequest(Method, Args, ARestMethod, Result);
    rtPut: DoPutRequest(Method, Args, ARestMethod, Result);
    rtDelete: DoDeleteRequest(ARestMethod, Result);
  end;
end;

procedure TRESTClient.EnumerateRESTMethods;
var
  LType: TRttiType;
  LMethod: TRttiMethod;
  LAttr: TCustomAttribute;
begin
  FMethods.Clear;

  LType := FCtx.GetType(FProxyTypeInfo);
  for LMethod in LType.GetMethods do
  begin
    if IsMethodMarked(LMethod) then
    begin
      FMethods.Add(LMethod.Handle, GetRESTMethod(LMethod, LType));
    end;
  end;

  for LAttr in LType.GetAttributes do
  begin
    if LAttr is PathAttribute then
    begin
      FURL := FURL + PathAttribute(LAttr).Path;
      Exit;
    end;
  end;
end;

procedure TRESTClient.FillRestMethodParameters(const Args: TArray<TValue>; ARestMethod: TRESTMethod; AMethod: TRttiMethod);
var
  i: Integer;
  LParameters: TArray<TRttiParameter>;
begin
  LParameters := AMethod.GetParameters;
  for i := Low(Args) to High(Args) do
  begin
    ARestMethod.Parameters[i].Value := ConsumeMediaTypeAsString(LParameters[i].ParamType, Args[i], ARestMethod);
  end;
end;

function TRESTClient.GenerateSourceContent(ARestMethod: TRESTMethod): TStream;
var
  i: Integer;
  LParamValue, LParamName: string;
begin
  Result := TStringStream.Create('', TEncoding.UTF8);
  for i := 0 to ARestMethod.Parameters.Count - 1 do
  begin
    if i <> 0 then
      TStringStream(Result).WriteString('&');

    LParamValue := ARestMethod.Parameters[i].ToString;
    LParamName := ARestMethod.Parameters[i].Name;
    if FEncodeParameters then
    begin
      LParamName := UrlEncodeRFC3986(LParamName);
      LParamValue := UrlEncodeRFC3986(LParamValue);
    end;
    TStringStream(Result).WriteString(Format('%S=%S',
      [LParamName, LParamValue]));
  end;
end;

function TRESTClient.GenerateUrl(ARestMethod: TRESTMethod): string;
var
  i: Integer;
  LParamValue, LParamName: string;
begin
  Result := FURL;
  if ARestMethod.Path <> '' then
    Result := Result + ARestMethod.Path;

  if ARestMethod.RequestType <> rtGet then
    Exit;

  Result := DoCheckPathParameters(Result, ARestMethod);

  if ARestMethod.Parameters.Count > 0 then
    Result := Result + '?';

  for i := 0 to ARestMethod.Parameters.Count - 1 do
  begin
    if i <> 0 then
      Result := Result + '&';

    LParamName := ARestMethod.Parameters[i].Name;
    LParamValue := ARestMethod.Parameters[i].ToString;
    if FEncodeParameters then
    begin
      LParamName := UrlEncodeRFC3986(LParamName);
      LParamValue := UrlEncodeRFC3986(LParamValue);
    end;

    Result := Result + Format('%S=%S', [LParamName, LParamValue]);
  end;
end;

function TRESTClient.GetRequestType(AMethod: TRttiMethod): TRequestType;
var
  LAttrib: TCustomAttribute;
begin
  for LAttrib in AMethod.GetAttributes do
  begin
    if LAttrib is GETAttribute then
      Exit(rtGet)
    else if LAttrib is POSTAttribute then
      Exit(rtPost)
    else if LAttrib is PUTAttribute then
      Exit(rtPut)
    else if LAttrib is DELETEAttribute then
      Exit(rtDelete);
  end;
  Result := rtGet;
end;

function TRESTClient.GetRESTMethod(AMethod: TRttiMethod; AType: TRttiType): TRESTMethod;
var
  LAttr: TCustomAttribute;
  LParam: TRttiParameter;
  LRestParam: TRESTMethodParameter;
begin
  Result := TRESTMethod.Create;
  Result.Name := AMethod.Name;

  for LParam in AMethod.GetParameters do
  begin
    LRestParam := TRESTMethodParameter.Create;
    LRestParam.Name := LParam.Name;
    Result.Parameters.Add(LRestParam);
  end;

  for LAttr in AType.GetAttributes do
  begin
    if LAttr.ClassType = QueryParamNameValueAttribute then
    begin
      LRestParam := TRESTMethodParameter.Create;
      LRestParam.Name := QueryParamNameValueAttribute(LAttr).Name;
      LRestParam.Value := QueryParamNameValueAttribute(LAttr).Value;
      Result.Parameters.Add(LRestParam);
    end;
  end;

  for LAttr in AMethod.GetAttributes do
  begin
    if LAttr is GETAttribute then
      Result.RequestType := rtGet
    else if LAttr is POSTAttribute then
      Result.RequestType := rtPost
    else if LAttr is PUTAttribute then
      Result.RequestType := rtPut
    else if LAttr is DELETEAttribute then
      Result.RequestType := rtDelete
    else if LAttr is PathAttribute then
      Result.Path := PathAttribute(LAttr).Path
    else if LAttr.ClassType = ConsumesAttribute then
      Result.ConsumeMediaType := ConsumesAttribute(LAttr).MediaType
    else if LAttr.ClassType = ProducesAttribute then
      Result.ProduceMediaType := ProducesAttribute(LAttr).MediaType
    else if LAttr.ClassType = QueryParamNameValueAttribute then
    begin
      LRestParam := TRESTMethodParameter.Create;
      LRestParam.Name := QueryParamNameValueAttribute(LAttr).Name;
      LRestParam.Value := QueryParamNameValueAttribute(LAttr).Value;
      Result.Parameters.Add(LRestParam);
    end;
  end;
end;

function TRESTClient.GetSerializedDataString(const AValue: TValue; ARestMethod: TRESTMethod): string;
var
  LObject: TObject;
begin
  Result := '';
  if AValue.IsEmpty then
    Exit;

  if AValue.IsObject then
  begin
    LObject := AValue.AsObject;
    if not Assigned(LObject) then
      Exit;

    if LObject is TStringStream then
      Result := TStringStream(LObject).DataString
    else
    begin
      //serialize object to string
      Result := SerializeObjectToString(LObject, ARestMethod);
    end;
  end
  else
  begin
    Result := AValue.ToString;
  end;
end;

function TRESTClient.HasAuthentication: Boolean;
begin
  Result := Assigned(FAuthentication) and (FAuthentication.DoAuthenticate);
end;

function TRESTClient.IsHttps: Boolean;
begin
  Result := StartsText('https', FURL);
end;

function TRESTClient.IsMethodMarked(AMethod: TRttiMethod): Boolean;
var
  LAttrib: TCustomAttribute;
begin
  for LAttrib in AMethod.GetAttributes do
  begin
    Result := (LAttrib is GETAttribute) or (LAttrib is POSTAttribute)
      or (LAttrib is DELETEAttribute) or (LAttrib is PUTAttribute);
    if Result then
      Exit;
  end;
  Result := False;
end;

function TRESTClient.SerializeObjectToString(AObject: TObject; ARestMethod: TRESTMethod): string;
begin
  Result := '';
  case ARestMethod.ProduceMediaType of
    MEDIA_TYPE.JSON: TSvSerializer.SerializeObject(AObject, Result, sstSuperJson);
    MEDIA_TYPE.XML: TSvSerializer.SerializeObject(AObject, Result, sstNativeXML);
  end;
end;

procedure TRESTClient.SetHttpClient(const AHttpClientName: string);
begin
  FHttp := THTTPClientFactory.GetInstance(AHttpClientName);
  if IsHttps then
    FHttp.SetUpHttps();
end;


function TRESTClient.UrlEncode(const S: string): string;
var
  Ch : Char;
begin
  Result := '';
  for Ch in S do
  begin
    if ((Ch >= '0') and (Ch <= '9')) or
       ((Ch >= 'a') and (Ch <= 'z')) or
       ((Ch >= 'A') and (Ch <= 'Z')) or
       (Ch = '.') or (Ch = '-') or (Ch = '_') or (Ch = '~') then
      Result := Result + Ch
    else
      Result := Result + '%' + SysUtils.IntToHex(Ord(Ch), 2);
  end;
end;

function TRESTClient.UrlEncodeRFC3986(const URL: string): string;
var
  URL1: string;
begin
  URL1 := URLEncode(URL);
  URL1 := StringReplace(URL1, '', '+', [rfReplaceAll, rfIgnoreCase]);
  Result := URL1;
end;

end.